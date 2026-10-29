import Foundation
import Observation

/// One offer of the notification permission flow: which step it starts on, where it comes from, and what the OS
/// permission was when it was decided.
struct NotificationPrompt: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Step 1/2 (the permission), followed by step 2/2 (the campaign consent) once the user says yes.
        case permission
        /// Step 2/2 alone: the user's notifications are already on, only the campaign consent is missing.
        case consent
    }

    let id = UUID()
    let kind: Kind
    /// `.prompt` for a first offer, `.reask` for the one contextual second offer.
    let source: NotificationPromptSource
    let permission: NotificationPermission

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// Decides when the notification permission flow is offered, and hands it to the screen that presents it.
///
/// Triggers (NOTIFICATIONS.md §1.1): the first offer once the user has a profile and the onboarding tour is gone
/// (`offerFirstRunIfNeeded`); one contextual re-ask of the permission after the user's next successful exam
/// submission (`examWasSubmitted`); one re-ask of the campaign consent when the inbox is opened
/// (`inboxConsentReask`). Each re-ask is due at the earliest `NotificationPromptHistory.reaskDelay` after the "no"
/// it follows. Everything shown is recorded in the history *when it appears* (see `NotificationPermissionFlowModel`),
/// so an offer that never reached the screen is not used up.
///
/// A permission offer is queued in `pending`; `RootView`'s presenter shows it (`present()`) as soon as no other
/// modal is in the way, because SwiftUI cannot present a sheet over another one.
@Observable
final class NotificationPromptCoordinator {
    /// An offer waiting for the screen to be free.
    private(set) var pending: NotificationPrompt?
    /// The offer on screen (bound to the presenter's sheet).
    var presented: NotificationPrompt?

    @ObservationIgnored let notifications: any NotificationServicing
    @ObservationIgnored let settings: NotificationSettingsStore
    @ObservationIgnored let history: NotificationPromptHistory
    @ObservationIgnored let analytics: any AnalyticsTracking

    init(
        notifications: any NotificationServicing,
        settings: NotificationSettingsStore,
        history: NotificationPromptHistory,
        analytics: any AnalyticsTracking
    ) {
        self.notifications = notifications
        self.settings = settings
        self.history = history
        self.analytics = analytics
    }

    // MARK: - Triggers

    /// Grants provisional authorization silently when the user was never asked, so notifications reach the
    /// Notification Center from the first launch on (no prompt; step 1/2 asks for the full permission later).
    func prepare() async {
        guard await notifications.permission() == .notDetermined else { return }
        await notifications.requestProvisionalAuthorization()
    }

    /// Queues the first offer, when one is due: the permission step while notifications are not fully allowed (and
    /// it was never offered), or — for someone who allowed notifications before campaigns needed consent — the
    /// consent step alone, once, unless they already answered on another device.
    func offerFirstRunIfNeeded() async {
        guard isFree else { return }
        let permission = await notifications.permission()
        // An earlier build offered the permission without recording a "no": treat a device that was offered it
        // and still has no full permission as having said no, so the contextual re-ask can still come.
        if history.hasOfferedPriming, permission != .authorized {
            history.recordPermissionDeclined()
        }
        switch permission {
        case .notDetermined, .provisional:
            guard !history.hasOfferedPriming, isFree else { return }
            pending = NotificationPrompt(kind: .permission, source: .prompt, permission: permission)
        case .authorized:
            guard !history.hasOfferedConsent, await settings.waitUntilLoaded(), !settings.hasAnswered, isFree else {
                return
            }
            pending = NotificationPrompt(kind: .consent, source: .prompt, permission: permission)
        case .denied:
            return
        }
    }

    /// The user's exam went through. Queues the one re-ask of the permission ("Onaylanınca haber verelim mi?")
    /// when it is due and notifications are still not fully allowed.
    func examWasSubmitted() async {
        guard isFree, history.shouldReaskPermission() else { return }
        let permission = await notifications.permission()
        guard permission != .authorized, isFree else { return }
        pending = NotificationPrompt(kind: .permission, source: .reask, permission: permission)
    }

    /// The inbox was opened. Returns the one re-ask of the campaign consent when it is due — the user said no
    /// long enough ago and has not turned campaigns on since — for the inbox to present itself (a sheet over the
    /// inbox sheet cannot come from `RootView`).
    func inboxConsentReask() async -> NotificationPrompt? {
        guard isFree, history.shouldReaskConsent(), await settings.waitUntilLoaded(timeout: .seconds(2)),
              !settings.marketingEnabled, isFree else { return nil }
        return NotificationPrompt(kind: .consent, source: .reask, permission: await notifications.permission())
    }

    // MARK: - Presenting

    /// Moves the queued offer on screen. Called by the presenter once nothing else is presented.
    func present() {
        guard let pending else { return }
        presented = pending
        self.pending = nil
    }

    /// Withdraws the queued offer and closes the one on screen: a tapped push needs the screen, and a user who
    /// signs out leaves nothing queued for the next one. Whatever was not answered counts as a "no" (see
    /// `NotificationPermissionFlowModel.sheetDidClose()`).
    func dismiss() {
        pending = nil
        presented = nil
    }

    /// The flow for `prompt`, wired to this coordinator's services.
    func makeFlow(for prompt: NotificationPrompt) -> NotificationPermissionFlowModel {
        NotificationPermissionFlowModel(
            prompt: prompt,
            notifications: notifications,
            settings: settings,
            history: history,
            analytics: analytics
        )
    }

    // MARK: - Private

    /// Nothing is queued or on screen: a new offer may be queued.
    private var isFree: Bool { pending == nil && presented == nil }
}

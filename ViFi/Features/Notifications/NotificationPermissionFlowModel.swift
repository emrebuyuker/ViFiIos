import Foundation
import Observation

/// The notification permission flow of one offer (NOTIFICATIONS.md §1.1): step 1/2 asks for the OS permission,
/// and only once the user said yes to that, step 2/2 asks for the campaign consent (the Apple 4.5.4 opt-in).
///
/// It records what is shown and answered in `NotificationPromptHistory` (for the re-ask schedule), writes the
/// consent through `NotificationSettingsStore` and reports analytics. Whatever the user leaves unanswered — a
/// swipe down, a push that needs the screen — counts as a "no" for the schedule (`sheetDidClose()`), though no
/// consent is written for it: not answering never opts anyone in.
@Observable
final class NotificationPermissionFlowModel {
    enum Page: Equatable {
        case permission
        case consent
    }

    let prompt: NotificationPrompt
    private(set) var page: Page
    /// The OS permission as last read (it is re-read after the system prompt).
    private(set) var permission: NotificationPermission
    /// A system prompt or a consent write is in progress.
    private(set) var isWorking = false
    /// The consent could not be saved; the user may try again or close.
    private(set) var saveFailed = false
    /// The flow has ended; the view closes itself.
    private(set) var isFinished = false

    @ObservationIgnored private let notifications: any NotificationServicing
    @ObservationIgnored private let settings: NotificationSettingsStore
    @ObservationIgnored private let history: NotificationPromptHistory
    @ObservationIgnored private let analytics: any AnalyticsTracking
    @ObservationIgnored private var hasStarted = false
    /// The current page was answered (or its "no" recorded), so closing it is not a further "no".
    @ObservationIgnored private var isResolved = false

    init(
        prompt: NotificationPrompt,
        notifications: any NotificationServicing,
        settings: NotificationSettingsStore,
        history: NotificationPromptHistory,
        analytics: any AnalyticsTracking
    ) {
        self.prompt = prompt
        self.notifications = notifications
        self.settings = settings
        self.history = history
        self.analytics = analytics
        permission = prompt.permission
        page = prompt.kind == .permission ? .permission : .consent
    }

    /// The system will not ask again: only the Settings app can turn notifications on.
    var needsSettingsApp: Bool { permission == .denied }

    // MARK: - Showing

    /// The first page is on screen: records it and reports it.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        switch page {
        case .permission:
            if prompt.source == .reask {
                history.markPermissionReaskShown()
            } else {
                history.markPrimingOffered()
            }
            analytics.track(.notificationPrimingShown(source: prompt.source))
        case .consent:
            consentDidAppear()
        }
    }

    // MARK: - Step 1/2: the permission

    /// "Bildirimleri Aç": asks for the full permission. Granted (or already provisional) leads on to the consent
    /// unless the user answered it on another device; refused by the system counts as a "no".
    func enableNotifications() async {
        guard page == .permission, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        analytics.track(.notificationPrimingAccepted(source: prompt.source))
        await notifications.requestAuthorization()
        permission = await notifications.permission()
        guard permission.deliversNotifications else {
            history.recordPermissionDeclined()
            finish()
            return
        }
        if settings.hasAnswered {
            finish()
        } else {
            page = .consent
            consentDidAppear()
        }
    }

    /// "Ayarlar'ı Aç" was tapped (the view opens the Settings app): the user is acting on it, so it is no "no".
    func settingsWereOpened() {
        analytics.track(.notificationPrimingAccepted(source: prompt.source))
        finish()
    }

    /// "Şimdi Değil".
    func declineNotifications() {
        guard page == .permission else { return }
        analytics.track(.notificationPrimingDeclined(source: prompt.source))
        history.recordPermissionDeclined()
        finish()
    }

    // MARK: - Step 2/2: the consent

    /// "Evet, fırsatları bildir" / "Hayır, teşekkürler": writes the answer. A failed write keeps the page open
    /// with an error, so the answer is never silently lost.
    func answerConsent(_ marketing: Bool) async {
        guard page == .consent, !isWorking else { return }
        isWorking = true
        saveFailed = false
        defer { isWorking = false }
        guard await settings.setMarketing(marketing, source: .prompt) else {
            saveFailed = true
            return
        }
        analytics.track(marketing
            ? .marketingConsentAccepted(source: prompt.source)
            : .marketingConsentDeclined(source: prompt.source))
        if !marketing {
            history.recordConsentDeclined()
        }
        finish()
    }

    // MARK: - Closing

    /// The sheet went away, whatever the way. An unanswered page counts as a "no" for the re-ask schedule.
    func sheetDidClose() {
        guard !isResolved else { return }
        isResolved = true
        switch page {
        case .permission: history.recordPermissionDeclined()
        case .consent: history.recordConsentDeclined()
        }
    }

    // MARK: - Private

    private func consentDidAppear() {
        history.markConsentOffered()
        // Only the stand-alone consent offer is the consent's re-ask; the consent page that follows a permission
        // offer (even a re-asked one) is its first.
        if prompt.kind == .consent, prompt.source == .reask {
            history.markConsentReaskShown()
        }
        analytics.track(.marketingConsentShown(source: prompt.source))
    }

    private func finish() {
        isResolved = true
        isFinished = true
    }
}

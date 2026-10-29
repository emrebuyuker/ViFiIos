import Foundation
import Testing
@testable import ViFi

/// When the notification permission flow is offered: the first offer, the two contextual re-asks, and that nothing
/// is offered that should not be.
@MainActor
@Suite("NotificationPromptCoordinator", .timeLimit(.minutes(1)))
final class NotificationPromptCoordinatorTests {
    private static let uid = "user-1"
    private static let day: TimeInterval = 24 * 60 * 60

    private let notifications = StubNotificationService()
    private let service = ScriptedNotificationSettingsService()
    private let settings: NotificationSettingsStore
    private let storage: TemporaryDefaults
    private let clock = TestClock()
    private let analytics = AnalyticsSpy()
    private let history: NotificationPromptHistory
    private let coordinator: NotificationPromptCoordinator
    private var observation: Task<Void, Never>?

    init() throws {
        storage = try TemporaryDefaults()
        settings = NotificationSettingsStore(service: service, saveTimeout: .milliseconds(150))
        history = NotificationPromptHistory(defaults: storage.defaults, now: clock.now)
        coordinator = NotificationPromptCoordinator(
            notifications: notifications, settings: settings, history: history, analytics: analytics
        )
    }

    deinit {
        observation?.cancel()
    }

    // MARK: - Silent permission

    @Test("A user who was never asked is given provisional authorization without a prompt")
    func provisionalForNewUsers() async {
        await coordinator.prepare()

        #expect(notifications.provisionalRequests == 1)
        #expect(notifications.authorizationRequests == 0)
        #expect(notifications.current == .provisional)
    }

    @Test("Provisional authorization is not requested once the user has decided or already has it", arguments: [
        NotificationPermission.provisional, .authorized, .denied,
    ])
    func noProvisionalOtherwise(permission: NotificationPermission) async {
        notifications.current = permission

        await coordinator.prepare()

        #expect(notifications.provisionalRequests == 0)
        #expect(notifications.current == permission)
    }

    // MARK: - First offer

    @Test("The permission step is offered to a user who was never asked", arguments: [
        NotificationPermission.notDetermined, .provisional,
    ])
    func offersThePermissionStep(permission: NotificationPermission) async {
        notifications.current = permission

        await coordinator.offerFirstRunIfNeeded()

        #expect(coordinator.pending?.kind == .permission)
        #expect(coordinator.pending?.source == .prompt)
        #expect(coordinator.pending?.permission == permission)
    }

    @Test("The permission step is not offered again once it was shown")
    func notOfferedTwice() async {
        notifications.current = .provisional
        history.markPrimingOffered()

        await coordinator.offerFirstRunIfNeeded()

        #expect(coordinator.pending == nil)
    }

    @Test("A queued offer is not queued twice, nor while one is on screen")
    func noDuplicates() async {
        notifications.current = .provisional
        await coordinator.offerFirstRunIfNeeded()
        let first = coordinator.pending

        await coordinator.offerFirstRunIfNeeded()
        #expect(coordinator.pending == first)

        coordinator.present()
        #expect(coordinator.presented == first)
        #expect(coordinator.pending == nil)
        await coordinator.offerFirstRunIfNeeded()
        #expect(coordinator.pending == nil)
    }

    @Test("Nothing is offered when the system will not ask again")
    func noOfferWhenDenied() async {
        notifications.current = .denied

        await coordinator.offerFirstRunIfNeeded()

        #expect(coordinator.pending == nil)
    }

    @Test("Someone who allowed notifications before consent existed is offered the consent alone, once")
    func consentCatchUp() async {
        notifications.current = .authorized
        await startObserving(consent: nil)

        await coordinator.offerFirstRunIfNeeded()

        #expect(coordinator.pending?.kind == .consent)
        #expect(coordinator.pending?.source == .prompt)

        history.markConsentOffered()
        coordinator.dismiss()
        await coordinator.offerFirstRunIfNeeded()
        #expect(coordinator.pending == nil)
    }

    @Test("The consent is not offered to someone who already answered (on any device)", arguments: [true, false])
    func noCatchUpWhenAnswered(marketing: Bool) async {
        notifications.current = .authorized
        await startObserving(consent: NotificationConsent(marketing: marketing))

        await coordinator.offerFirstRunIfNeeded()

        #expect(coordinator.pending == nil)
    }

    @Test("The consent is not offered while the record cannot be read")
    func noCatchUpWhenUnreadable() async {
        notifications.current = .authorized
        service.feed = .failure(.unavailable)
        observation = Task { await settings.observe(uid: Self.uid) }

        await coordinator.offerFirstRunIfNeeded()

        #expect(coordinator.pending == nil)
    }

    @Test("A device that was offered the permission by an earlier build and still has none can be re-asked")
    func legacyDeclineArmsTheReask() async {
        notifications.current = .notDetermined
        history.markPrimingOffered()

        await coordinator.offerFirstRunIfNeeded()
        #expect(coordinator.pending == nil)
        #expect(!history.shouldReaskPermission())

        clock.advance(by: 31 * Self.day)
        #expect(history.shouldReaskPermission())
    }

    // MARK: - Re-ask after a submission

    @Test("After a no and 30 days, the next submission offers the permission once more")
    func reaskAfterSubmission() async {
        notifications.current = .provisional
        history.recordPermissionDeclined()
        clock.advance(by: 31 * Self.day)

        await coordinator.examWasSubmitted()

        #expect(coordinator.pending?.kind == .permission)
        #expect(coordinator.pending?.source == .reask)
    }

    @Test("A submission before the 30 days are over offers nothing")
    func noReaskTooSoon() async {
        notifications.current = .provisional
        history.recordPermissionDeclined()
        clock.advance(by: 29 * Self.day)

        await coordinator.examWasSubmitted()

        #expect(coordinator.pending == nil)
    }

    @Test("A submission offers nothing without an earlier no")
    func noReaskWithoutNo() async {
        notifications.current = .provisional
        clock.advance(by: 400 * Self.day)

        await coordinator.examWasSubmitted()

        #expect(coordinator.pending == nil)
    }

    @Test("Someone who has since allowed notifications is not asked again")
    func noReaskWhenAllowed() async {
        notifications.current = .authorized
        history.recordPermissionDeclined()
        clock.advance(by: 31 * Self.day)

        await coordinator.examWasSubmitted()

        #expect(coordinator.pending == nil)
    }

    @Test("When the system refused, the re-ask carries that, so it can send the user to Settings")
    func reaskWhenDenied() async {
        notifications.current = .denied
        history.recordPermissionDeclined()
        clock.advance(by: 31 * Self.day)

        await coordinator.examWasSubmitted()

        #expect(coordinator.pending?.permission == .denied)
    }

    @Test("The re-ask is used up once it is shown")
    func reaskOnlyOnce() async throws {
        notifications.current = .provisional
        history.recordPermissionDeclined()
        clock.advance(by: 31 * Self.day)
        await coordinator.examWasSubmitted()
        let prompt = try #require(coordinator.pending)

        coordinator.present()
        let flow = coordinator.makeFlow(for: prompt)
        flow.start()
        flow.declineNotifications()
        coordinator.dismiss()

        clock.advance(by: 365 * Self.day)
        await coordinator.examWasSubmitted()
        #expect(coordinator.pending == nil)
    }

    @Test("A re-ask that never reached the screen is not used up")
    func queuedReaskNotUsedUp() async {
        notifications.current = .provisional
        history.recordPermissionDeclined()
        clock.advance(by: 31 * Self.day)
        await coordinator.examWasSubmitted()

        coordinator.dismiss()

        #expect(history.shouldReaskPermission())
    }

    // MARK: - Re-ask in the inbox

    @Test("After a consent no and 30 days, opening the inbox offers the consent once more")
    func consentReaskInInbox() async {
        await startObserving(consent: NotificationConsent(marketing: false))
        history.recordConsentDeclined()
        clock.advance(by: 31 * Self.day)

        let prompt = await coordinator.inboxConsentReask()

        #expect(prompt?.kind == .consent)
        #expect(prompt?.source == .reask)
    }

    @Test("The inbox offers nothing before 30 days, without a no, or after the user turned campaigns on")
    func noConsentReask() async {
        await startObserving(consent: NotificationConsent(marketing: false))
        #expect(await coordinator.inboxConsentReask() == nil, "No earlier no")

        history.recordConsentDeclined()
        clock.advance(by: 10 * Self.day)
        #expect(await coordinator.inboxConsentReask() == nil, "Too soon")

        clock.advance(by: 21 * Self.day)
        service.emit(.success(NotificationConsent(marketing: true)))
        #expect(await eventually { settings.marketingEnabled })
        #expect(await coordinator.inboxConsentReask() == nil, "Already on")
    }

    @Test("The consent re-ask is used up once shown")
    func consentReaskOnlyOnce() async throws {
        await startObserving(consent: NotificationConsent(marketing: false))
        history.recordConsentDeclined()
        clock.advance(by: 31 * Self.day)
        let prompt = try #require(await coordinator.inboxConsentReask())

        let flow = coordinator.makeFlow(for: prompt)
        flow.start()

        #expect(await coordinator.inboxConsentReask() == nil)
    }

    // MARK: - Presenting

    @Test("A queued offer moves on screen, and dismiss clears both")
    func presentAndDismiss() async {
        notifications.current = .provisional
        await coordinator.offerFirstRunIfNeeded()
        let prompt = coordinator.pending

        coordinator.present()
        #expect(coordinator.presented == prompt)
        #expect(coordinator.pending == nil)

        coordinator.dismiss()
        #expect(coordinator.presented == nil)
    }

    // MARK: - Helpers

    private func startObserving(consent: NotificationConsent?) async {
        service.feed = .success(consent)
        observation = Task { await settings.observe(uid: Self.uid) }
        #expect(await eventually { settings.isLoaded })
    }
}

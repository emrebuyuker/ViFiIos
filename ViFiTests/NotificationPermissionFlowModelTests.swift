import Foundation
import Testing
@testable import ViFi

/// The two-step flow itself: what each button does to the permission, the consent record, the history (the
/// re-ask schedule) and analytics.
@MainActor
@Suite("NotificationPermissionFlowModel", .timeLimit(.minutes(1)))
final class NotificationPermissionFlowModelTests {
    private static let uid = "user-1"
    private static let day: TimeInterval = 24 * 60 * 60

    private let notifications = StubNotificationService(.provisional)
    private let service = ScriptedNotificationSettingsService()
    private let settings: NotificationSettingsStore
    private let storage: TemporaryDefaults
    private let clock = TestClock()
    private let analytics = AnalyticsSpy()
    private let history: NotificationPromptHistory
    private var observation: Task<Void, Never>?

    init() throws {
        storage = try TemporaryDefaults()
        settings = NotificationSettingsStore(service: service, saveTimeout: .milliseconds(150))
        history = NotificationPromptHistory(defaults: storage.defaults, now: clock.now)
    }

    deinit {
        observation?.cancel()
    }

    // MARK: - Showing

    @Test("The first page is recorded and reported when it appears — once")
    func startRecordsAndReports() {
        let flow = makeFlow(.permission, .prompt)

        flow.start()
        flow.start()

        #expect(history.hasOfferedPriming)
        #expect(analytics.events == [.notificationPrimingShown(source: .prompt)])
    }

    @Test("A stand-alone consent offer starts on step 2/2 and records the consent as offered")
    func consentOnlyStart() {
        let flow = makeFlow(.consent, .prompt)

        flow.start()

        #expect(flow.page == .consent)
        #expect(history.hasOfferedConsent)
        #expect(!history.hasOfferedPriming)
        #expect(analytics.events == [.marketingConsentShown(source: .prompt)])
    }

    // MARK: - Step 1/2

    @Test("Enabling asks the system, then moves on to the consent")
    func enableLeadsToConsent() async {
        await startObserving(consent: nil)
        let flow = makeFlow(.permission, .prompt)
        flow.start()

        await flow.enableNotifications()

        #expect(notifications.authorizationRequests == 1)
        #expect(flow.permission == .authorized)
        #expect(flow.page == .consent)
        #expect(!flow.isFinished)
        #expect(history.hasOfferedConsent)
        #expect(analytics.events == [
            .notificationPrimingShown(source: .prompt),
            .notificationPrimingAccepted(source: .prompt),
            .marketingConsentShown(source: .prompt),
        ])
    }

    @Test("A system refusal ends the flow and counts as a no for the re-ask")
    func systemRefusal() async {
        await startObserving(consent: nil)
        notifications.permissionAfterRequest = .denied
        let flow = makeFlow(.permission, .prompt)
        flow.start()

        await flow.enableNotifications()

        #expect(flow.isFinished)
        #expect(flow.page == .permission)
        #expect(!history.hasOfferedConsent, "No consent is asked of someone who refused notifications")
        clock.advance(by: 31 * Self.day)
        #expect(history.shouldReaskPermission())
    }

    @Test("Someone who already answered the consent elsewhere is not asked again")
    func skipsConsentWhenAnswered() async {
        await startObserving(consent: NotificationConsent(marketing: false))
        let flow = makeFlow(.permission, .prompt)
        flow.start()

        await flow.enableNotifications()

        #expect(flow.isFinished)
        #expect(!history.hasOfferedConsent)
        #expect(service.writes.isEmpty)
    }

    @Test("Şimdi Değil ends the flow and starts the wait for the one re-ask")
    func notNow() {
        let flow = makeFlow(.permission, .prompt)
        flow.start()

        flow.declineNotifications()

        #expect(flow.isFinished)
        #expect(analytics.events.last == .notificationPrimingDeclined(source: .prompt))
        #expect(notifications.authorizationRequests == 0, "The system prompt is kept for a user who says yes")
        clock.advance(by: 30 * Self.day)
        #expect(history.shouldReaskPermission())
    }

    @Test("When the system will not ask again, the flow offers Settings and opening it counts as a yes")
    func deniedOffersSettings() {
        notifications.current = .denied
        history.recordPermissionDeclined()
        clock.advance(by: 31 * Self.day)
        let flow = makeFlow(.permission, .reask, permission: .denied)
        flow.start()

        #expect(flow.needsSettingsApp)
        flow.settingsWereOpened()
        flow.sheetDidClose()

        #expect(flow.isFinished)
        #expect(analytics.events == [
            .notificationPrimingShown(source: .reask),
            .notificationPrimingAccepted(source: .reask),
        ])
        #expect(notifications.authorizationRequests == 0, "The system cannot be asked again")
        #expect(!history.shouldReaskPermission())
    }

    @Test("A re-ask is recorded as shown, so it is offered only once")
    func reaskRecorded() {
        history.recordPermissionDeclined()
        clock.advance(by: 31 * Self.day)
        #expect(history.shouldReaskPermission())

        makeFlow(.permission, .reask).start()

        #expect(!history.shouldReaskPermission())
    }

    // MARK: - Step 2/2

    @Test("Yes writes the consent as a prompt answer and ends the flow")
    func consentYes() async {
        await startObserving(consent: nil)
        let flow = makeFlow(.consent, .prompt)
        flow.start()

        await flow.answerConsent(true)

        #expect(service.writes == [.init(marketing: true, source: .prompt, uid: Self.uid)])
        #expect(settings.marketingEnabled)
        #expect(flow.isFinished)
        #expect(analytics.events.last == .marketingConsentAccepted(source: .prompt))
        clock.advance(by: 400 * Self.day)
        #expect(!history.shouldReaskConsent(), "A yes needs no re-ask")
    }

    @Test("No writes the consent too, and starts the wait for the one re-ask")
    func consentNo() async {
        await startObserving(consent: nil)
        let flow = makeFlow(.consent, .prompt)
        flow.start()

        await flow.answerConsent(false)

        #expect(service.writes == [.init(marketing: false, source: .prompt, uid: Self.uid)])
        #expect(!settings.marketingEnabled)
        #expect(settings.hasAnswered)
        #expect(flow.isFinished)
        #expect(analytics.events.last == .marketingConsentDeclined(source: .prompt))
        clock.advance(by: 30 * Self.day)
        #expect(history.shouldReaskConsent())
    }

    @Test("A consent that cannot be saved keeps the page open with an error, and reports nothing")
    func consentSaveFails() async {
        await startObserving(consent: nil)
        service.writeError = ConsentWriteRejected()
        let flow = makeFlow(.consent, .prompt)
        flow.start()

        await flow.answerConsent(true)

        #expect(flow.saveFailed)
        #expect(!flow.isFinished)
        #expect(!settings.marketingEnabled)
        #expect(analytics.events == [.marketingConsentShown(source: .prompt)])

        service.writeError = nil
        await flow.answerConsent(true)
        #expect(!flow.saveFailed)
        #expect(flow.isFinished)
        #expect(settings.marketingEnabled)
    }

    @Test("The consent page after a re-asked permission is the consent's first offer, not its re-ask")
    func consentAfterPermissionReask() async {
        await startObserving(consent: nil)
        history.recordConsentDeclined()
        clock.advance(by: 31 * Self.day)
        let flow = makeFlow(.permission, .reask)
        flow.start()

        await flow.enableNotifications()

        #expect(flow.page == .consent)
        #expect(analytics.events.contains(.marketingConsentShown(source: .reask)))
        #expect(history.shouldReaskConsent(), "The consent's own re-ask is still unused")
    }

    // MARK: - Closing

    @Test("Closing the permission page unanswered counts as a no for the schedule, and writes no consent")
    func closingPermissionUnanswered() {
        let flow = makeFlow(.permission, .prompt)
        flow.start()

        flow.sheetDidClose()

        clock.advance(by: 30 * Self.day)
        #expect(history.shouldReaskPermission())
        #expect(service.writes.isEmpty)
    }

    @Test("Closing the consent page unanswered never opts the user in")
    func closingConsentUnanswered() {
        let flow = makeFlow(.consent, .prompt)
        flow.start()

        flow.sheetDidClose()

        clock.advance(by: 30 * Self.day)
        #expect(history.shouldReaskConsent())
        #expect(service.writes.isEmpty)
        #expect(!settings.marketingEnabled)
    }

    @Test("Closing after an answer changes nothing")
    func closingAfterAnswer() async {
        await startObserving(consent: nil)
        let flow = makeFlow(.consent, .prompt)
        flow.start()
        await flow.answerConsent(true)

        flow.sheetDidClose()

        clock.advance(by: 400 * Self.day)
        #expect(!history.shouldReaskConsent())
    }

    // MARK: - Helpers

    private func makeFlow(
        _ kind: NotificationPrompt.Kind,
        _ source: NotificationPromptSource,
        permission: NotificationPermission = .provisional
    ) -> NotificationPermissionFlowModel {
        NotificationPermissionFlowModel(
            prompt: NotificationPrompt(kind: kind, source: source, permission: permission),
            notifications: notifications,
            settings: settings,
            history: history,
            analytics: analytics
        )
    }

    private func startObserving(consent: NotificationConsent?) async {
        service.feed = .success(consent)
        observation = Task { await settings.observe(uid: Self.uid) }
        #expect(await eventually { settings.isLoaded })
    }
}

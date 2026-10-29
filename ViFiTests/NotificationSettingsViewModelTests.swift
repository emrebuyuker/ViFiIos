import Foundation
import Testing
@testable import ViFi

/// Account › Bildirim Ayarları: how the OS permission reads and what it offers, and the campaign switch.
@MainActor
@Suite("NotificationSettingsViewModel", .timeLimit(.minutes(1)))
final class NotificationSettingsViewModelTests {
    private static let uid = "user-1"

    private let notifications = StubNotificationService(.authorized)
    private let service = ScriptedNotificationSettingsService()
    private let settings: NotificationSettingsStore
    private let analytics = AnalyticsSpy()
    private let viewModel: NotificationSettingsViewModel
    private var observation: Task<Void, Never>?

    init() {
        settings = NotificationSettingsStore(service: service, saveTimeout: .milliseconds(150))
        viewModel = NotificationSettingsViewModel(notifications: notifications, settings: settings, analytics: analytics)
    }

    deinit {
        observation?.cancel()
    }

    // MARK: - Permission

    @Test("Each OS permission reads in words and offers the right way to turn it on", arguments: [
        (NotificationPermission.authorized, "Açık", false, false),
        (.provisional, "Sessiz", true, false),
        (.denied, "Kapalı", false, true),
        (.notDetermined, "Sorulmadı", true, false),
    ])
    func permissionStatus(permission: NotificationPermission, title: String, canRequest: Bool, needsSettings: Bool) async {
        notifications.current = permission

        await viewModel.refreshPermission()

        #expect(viewModel.permissionTitle == title)
        #expect(viewModel.canRequestPermission == canRequest)
        #expect(viewModel.needsSettingsApp == needsSettings)
        #expect((viewModel.permissionNote != nil) == (permission != .authorized))
    }

    @Test("Until the permission is read nothing is offered")
    func beforeFirstRead() {
        #expect(viewModel.permission == nil)
        #expect(!viewModel.canRequestPermission)
        #expect(!viewModel.needsSettingsApp)
    }

    @Test("Enabling asks the system and shows the new status")
    func enable() async {
        notifications.current = .provisional
        await viewModel.refreshPermission()

        await viewModel.enableNotifications()

        #expect(notifications.authorizationRequests == 1)
        #expect(viewModel.permission == .authorized)
        #expect(!viewModel.canRequestPermission)
    }

    @Test("Enabling does nothing when the system cannot be asked")
    func enableWhenDenied() async {
        notifications.current = .denied
        await viewModel.refreshPermission()

        await viewModel.enableNotifications()

        #expect(notifications.authorizationRequests == 0)
        #expect(viewModel.permission == .denied)
    }

    // MARK: - Campaign switch

    @Test("The switch is off and unavailable until the record is read")
    func switchBeforeLoad() async {
        #expect(!viewModel.isConsentAvailable)
        #expect(!viewModel.marketingEnabled)

        await viewModel.setMarketing(true)

        #expect(service.writes.isEmpty, "Nothing is written before the real answer is known")
    }

    @Test("Turning campaigns on writes a settings answer and reports it")
    func turnOn() async {
        await startObserving(consent: nil)

        await viewModel.setMarketing(true)

        #expect(service.writes == [.init(marketing: true, source: .settings, uid: Self.uid)])
        #expect(viewModel.marketingEnabled)
        #expect(viewModel.errorMessage == nil)
        #expect(analytics.events == [.marketingConsentAccepted(source: .settings)])
    }

    @Test("Turning campaigns off writes a settings answer and reports it")
    func turnOff() async {
        await startObserving(consent: NotificationConsent(marketing: true))
        #expect(viewModel.marketingEnabled)

        await viewModel.setMarketing(false)

        #expect(service.writes == [.init(marketing: false, source: .settings, uid: Self.uid)])
        #expect(!viewModel.marketingEnabled)
        #expect(analytics.events == [.marketingConsentDeclined(source: .settings)])
    }

    @Test("A switch that cannot be saved goes back and says so")
    func saveFails() async {
        await startObserving(consent: NotificationConsent(marketing: false))
        service.writeError = ConsentWriteRejected()

        await viewModel.setMarketing(true)

        #expect(!viewModel.marketingEnabled)
        #expect(viewModel.errorMessage != nil)
        #expect(analytics.events.isEmpty)

        service.writeError = nil
        await viewModel.setMarketing(true)
        #expect(viewModel.marketingEnabled)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("A record that cannot be read leaves the switch unavailable")
    func unreadableRecord() async {
        service.feed = .failure(.unavailable)
        observation = Task { await settings.observe(uid: Self.uid) }
        #expect(await eventually { settings.availability == .unavailable })

        #expect(viewModel.isConsentUnavailable)
        #expect(!viewModel.isConsentAvailable)
    }

    // MARK: - Helpers

    private func startObserving(consent: NotificationConsent?) async {
        service.feed = .success(consent)
        observation = Task { await settings.observe(uid: Self.uid) }
        #expect(await eventually { settings.isLoaded })
    }
}

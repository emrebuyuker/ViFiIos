import Foundation
import Observation

/// State and actions behind Account › Bildirim Ayarları: the OS permission (with the way to turn it on) and the
/// campaign-notification switch, which is bound live to the consent record.
@Observable
final class NotificationSettingsViewModel {
    /// The OS permission as last read; `nil` until the first read.
    private(set) var permission: NotificationPermission?
    /// The system prompt is up.
    private(set) var isRequestingPermission = false
    /// A consent write is in flight.
    private(set) var isSavingConsent = false
    var errorMessage: String?

    @ObservationIgnored private let notifications: any NotificationServicing
    @ObservationIgnored private let settings: NotificationSettingsStore
    @ObservationIgnored private let analytics: any AnalyticsTracking

    init(
        notifications: any NotificationServicing,
        settings: NotificationSettingsStore,
        analytics: any AnalyticsTracking
    ) {
        self.notifications = notifications
        self.settings = settings
        self.analytics = analytics
    }

    // MARK: - Permission

    /// How the OS permission reads on screen.
    var permissionTitle: String {
        switch permission {
        case .authorized: String(localized: "Açık")
        case .provisional: String(localized: "Sessiz")
        case .denied: String(localized: "Kapalı")
        case .notDetermined: String(localized: "Sorulmadı")
        case nil: String(localized: "Yükleniyor…")
        }
    }

    /// An explanation under the permission row, when the status needs one.
    var permissionNote: String? {
        switch permission {
        case .provisional:
            String(localized: "Bildirimler sessizce Bildirim Merkezi'ne düşüyor. Anında haberdar olmak için bildirimleri aç.")
        case .denied:
            String(localized: "Bildirimler kapalı. Açmak için Ayarlar'a git.")
        case .notDetermined:
            String(localized: "Bildirim izni henüz verilmedi.")
        case .authorized, nil:
            nil
        }
    }

    /// "Bildirimleri Aç" is offered: the system can still be asked.
    var canRequestPermission: Bool {
        permission == .notDetermined || permission == .provisional
    }

    /// "Ayarlar'ı Aç" is offered: only the Settings app can turn notifications on now.
    var needsSettingsApp: Bool {
        permission == .denied
    }

    func refreshPermission() async {
        permission = await notifications.permission()
    }

    /// Asks the system for the full permission, then re-reads the status.
    func enableNotifications() async {
        guard canRequestPermission, !isRequestingPermission else { return }
        isRequestingPermission = true
        defer { isRequestingPermission = false }
        await notifications.requestAuthorization()
        await refreshPermission()
    }

    // MARK: - Campaign consent

    /// Whether the record could be read, so the switch shows the user's real answer.
    var isConsentAvailable: Bool { settings.isLoaded }

    /// The record could not be read.
    var isConsentUnavailable: Bool { settings.availability == .unavailable }

    var marketingEnabled: Bool { settings.marketingEnabled }

    /// Turns campaigns on or off. The switch shows the new value at once and goes back when saving fails.
    func setMarketing(_ enabled: Bool) async {
        guard settings.isLoaded, !isSavingConsent else { return }
        isSavingConsent = true
        errorMessage = nil
        defer { isSavingConsent = false }
        if await settings.setMarketing(enabled, source: .settings) {
            analytics.track(enabled
                ? .marketingConsentAccepted(source: .settings)
                : .marketingConsentDeclined(source: .settings))
        } else {
            errorMessage = String(localized: "Tercihin kaydedilemedi. Bağlantını kontrol edip tekrar dene.")
        }
    }
}

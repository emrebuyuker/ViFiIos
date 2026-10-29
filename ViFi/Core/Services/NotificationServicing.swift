import Foundation
import UserNotifications

/// Whether the user has allowed the app to show notifications.
nonisolated enum NotificationPermission: Sendable {
    case notDetermined
    case denied
    /// Provisional: notifications arrive quietly in the Notification Center, with no banner or sound, until the
    /// user keeps them (or turns them off). Granted without asking (`requestProvisionalAuthorization()`).
    case provisional
    /// Fully allowed (including ephemeral, which only App Clips get).
    case authorized

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .provisional: self = .provisional
        default: self = .authorized
        }
    }

    /// Whether the app may deliver notifications at all, quietly or not.
    var deliversNotifications: Bool {
        switch self {
        case .authorized, .provisional: true
        case .notDetermined, .denied: false
        }
    }
}

/// Requests and reports the OS notification permission. The app only asks to receive notifications; sending is
/// the server's job (NOTIFICATIONS.md).
protocol NotificationServicing: AnyObject {
    /// The current authorization status.
    func permission() async -> NotificationPermission

    /// Grants provisional authorization when the user was never asked: no system prompt, and notifications land
    /// quietly in the Notification Center. Registers for remote notifications on success. Does nothing once the
    /// user has decided (or was already given provisional authorization). Returns whether it granted.
    @discardableResult
    func requestProvisionalAuthorization() async -> Bool

    /// Shows the system permission prompt (once per install; from provisional it offers the upgrade) and
    /// registers for remote notifications on grant. Returns whether permission was granted.
    @discardableResult
    func requestAuthorization() async -> Bool
}

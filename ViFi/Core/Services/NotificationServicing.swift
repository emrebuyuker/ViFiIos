import Foundation
import UserNotifications

/// Whether the user has allowed the app to show notifications.
nonisolated enum NotificationPermission: Sendable {
    case notDetermined
    case denied
    /// Authorized, provisional or ephemeral — the app may show notifications.
    case authorized

    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        default: self = .authorized
        }
    }
}

/// Requests and reports the OS notification permission. Sending notifications is out of the app's scope (done
/// from the Firebase Console in v1); the app only asks to receive them.
protocol NotificationServicing: AnyObject {
    /// The current authorization status.
    func permission() async -> NotificationPermission

    /// Shows the system permission prompt (once per install) and registers for remote notifications on grant.
    /// Returns whether permission was granted.
    @discardableResult
    func requestAuthorization() async -> Bool
}

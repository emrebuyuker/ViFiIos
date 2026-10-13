import UIKit
import UserNotifications

/// Live notification permission, backed by `UNUserNotificationCenter`. No Firebase: registering for remote
/// notifications drives the APNs → FCM token flow set up in `AppDelegate`.
final class SystemNotificationService: NotificationServicing {
    func permission() async -> NotificationPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return NotificationPermission(settings.authorizationStatus)
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .badge, .sound])) ?? false
        if granted {
            UIApplication.shared.registerForRemoteNotifications()
        }
        return granted
    }
}

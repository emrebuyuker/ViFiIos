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
    func requestProvisionalAuthorization() async -> Bool {
        // Only a user who was never asked: asking again after a decision would change nothing but cost a call.
        guard await permission() == .notDetermined else { return false }
        return await request(options: [.alert, .badge, .sound, .provisional])
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        await request(options: [.alert, .badge, .sound])
    }

    private func request(options: UNAuthorizationOptions) async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: options)) ?? false
        if granted {
            UIApplication.shared.registerForRemoteNotifications()
        }
        return granted
    }
}

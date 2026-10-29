import FirebaseAuth
import FirebaseCore
import FirebaseMessaging
import os
import UIKit
import UserNotifications

/// The single FCM topic every signed-in device subscribes to, so a broadcast to everyone also reaches app
/// versions that do not register their device token (4.0.0 reads the public announcements, too). Segmented and
/// personal notifications go to the registered device tokens instead (`DeviceRegistrationStore`).
enum PushTopic {
    static let broadcast = "all"
}

/// Forwards what phone sign-in needs from the system to Firebase Auth (the APNs token and the silent pushes it
/// verifies the app with), and hosts Cloud Messaging: it bridges the APNs token to FCM, subscribes to the
/// broadcast topic, and presents / handles taps on the notifications the app receives. (The reCAPTCHA
/// fallback's URL is forwarded by `RootView.onOpenURL`.)
///
/// Firebase's app delegate swizzling is off (`FirebaseAppDelegateProxyEnabled = NO`) so this stays
/// deterministic under the SwiftUI lifecycle — the APNs token must be handed to both Auth and Messaging by
/// hand. Nothing here touches Firebase unless it has been configured, which never happens on sample data
/// (`-ViFiMockData`).
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// The app's services, built at launch (or on first use, which is never earlier).
    ///
    /// Not built in `ViFiApp`'s initialiser: that runs before `UIApplication` exists, and Firebase Auth (created
    /// by `FirebaseApp.configure()`) sets up phone sign-in's APNs and notification handling only when the
    /// application already exists, without ever retrying.
    private(set) lazy var environment = AppEnvironment.makeDefault()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Configures Firebase before the APNs callbacks below can arrive.
        let environment = environment
        // Silent pushes (phone sign-in verification) need no permission prompt; user-facing notifications are
        // only shown once the user grants permission (requested from the UI, not here).
        if !AppEnvironment.usesMockData() {
            application.registerForRemoteNotifications()
            if FirebaseApp.app() != nil {
                Messaging.messaging().delegate = self
                UNUserNotificationCenter.current().delegate = self
            }
            // Trim the on-disk file cache back within budget once per launch, while the app is idle.
            Task { await environment.fileLoader.pruneDiskCache() }
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        guard let auth = FirebaseAuthService.configuredAuth else { return }
        // `.unknown` lets Firebase detect the sandbox or production APNs environment from the provisioning profile.
        auth.setAPNSToken(deviceToken, type: .unknown)
        // Swizzling is off, so FCM needs the APNs token handed to it too, or it never produces a token.
        Messaging.messaging().apnsToken = deviceToken
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        // Phone sign-in then falls back to reCAPTCHA (always the case on the simulator). Telling Firebase spares
        // every code request its 5 s wait for an APNs token.
        let reason = String(describing: error)
        Logger.app.notice("Remote notification registration failed: \(reason, privacy: .public)")
        FirebaseAuthService.configuredAuth?.application(application, didFailToRegisterForRemoteNotificationsWithError: error)
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        // Firebase Auth consumes its verification pushes; hand anything else to Messaging (swizzling is off).
        if FirebaseAuthService.configuredAuth?.canHandleNotification(userInfo) != true, FirebaseApp.app() != nil {
            Messaging.messaging().appDidReceiveMessage(userInfo)
        }
        completionHandler(.noData)
    }
}

// MARK: - Cloud Messaging

extension AppDelegate: MessagingDelegate {
    /// Fires once the FCM token is available (at launch and on refresh). Hands it to the device registration
    /// (stored under the signed-in user, now or at sign-in) and subscribes to the broadcast topic, which is
    /// idempotent, so re-subscribing on every launch is safe.
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        environment.deviceRegistration.tokenDidChange(fcmToken)
        messaging.subscribe(toTopic: PushTopic.broadcast) { error in
            if let error {
                Logger.app.notice("Broadcast topic subscribe failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

// MARK: - Notification presentation

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Shows notifications that arrive while the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        if FirebaseApp.app() != nil {
            Messaging.messaging().appDidReceiveMessage(notification.request.content.userInfo)
        }
        return [.banner, .list, .sound]
    }

    /// Handles a tap on a notification: the notification inbox opens on it (once the app is past its gates, on a
    /// cold start as well as a warm one — see `NotificationRouter`). A push without a `notificationId` still
    /// opens the inbox, just without a highlight. The tap is also reported to Messaging for delivery metrics.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        if FirebaseApp.app() != nil {
            Messaging.messaging().appDidReceiveMessage(userInfo)
        }
        environment.notificationRouter.receive(notificationId: NotificationPayloadParser.notificationId(fromPush: userInfo))
    }
}

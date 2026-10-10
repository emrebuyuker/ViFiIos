import FirebaseAuth
import os
import UIKit

/// Forwards what phone sign-in needs from the system to Firebase Auth: the APNs token and the silent
/// pushes it verifies the app with. (The reCAPTCHA fallback's URL is forwarded by `RootView.onOpenURL`.)
///
/// Firebase's app delegate swizzling is off (`FirebaseAppDelegateProxyEnabled = NO`) so this stays
/// deterministic under the SwiftUI lifecycle. Nothing here touches Firebase unless it has been configured,
/// which never happens on sample data (`-ViFiMockData`).
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
        _ = environment
        // Silent pushes need no permission prompt.
        if !AppEnvironment.usesMockData() {
            application.registerForRemoteNotifications()
        }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        guard let auth = FirebaseAuthService.configuredAuth else { return }
        // `.unknown` lets Firebase detect the sandbox or production APNs environment from the provisioning profile.
        auth.setAPNSToken(deviceToken, type: .unknown)
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
        // Firebase Auth consumes its verification pushes. ViFi sends no notifications of its own, so anything
        // else is ignored as well.
        _ = FirebaseAuthService.configuredAuth?.canHandleNotification(userInfo)
        completionHandler(.noData)
    }
}

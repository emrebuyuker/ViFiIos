import DeviceCheck
@preconcurrency import FirebaseAppCheck
import FirebaseCore

/// Chooses how the app proves to Firebase that requests come from the genuine ViFi app (App Check).
///
/// - Debug builds and the simulator use the debug provider: its token is printed to the console on first
///   launch and must be registered under *App Check › Apps › Manage debug tokens*.
/// - Release builds use App Attest, or DeviceCheck on devices without App Attest support.
///
/// Installed with `AppCheck.setAppCheckProviderFactory(_:)` before `FirebaseApp.configure()`. Firebase calls
/// it from its own queues, hence `nonisolated`.
nonisolated final class ViFiAppCheckProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> (any AppCheckProvider)? {
        #if DEBUG || targetEnvironment(simulator)
        return AppCheckDebugProvider(app: app)
        #else
        if DCAppAttestService.shared.isSupported {
            return AppAttestProvider(app: app)
        }
        return DeviceCheckProvider(app: app)
        #endif
    }
}

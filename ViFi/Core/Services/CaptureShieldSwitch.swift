import Foundation

/// The screen-capture shield's switch for this launch.
///
/// The shield has no remote setting and no launch argument that turns it off: the app never changes its behaviour from a
/// server flag (owner decision, 16 November 2026, App Review). It is on in every launch; it fails open only on its own,
/// when the OS build offers no shield or `CaptureShieldCrashGuard` trips.
final class CaptureShieldSwitch {
    /// Keys a pre-release build stored for the removed remote switch; cleared so nothing stale is left behind.
    static let retiredKeys = ["captureShield.remoteEnabled", "captureShield.remoteCoverMode"]

    /// - Parameter defaults: Where the retired remote-switch keys are cleared.
    init(defaults: UserDefaults = .standard) {
        for key in Self.retiredKeys {
            defaults.removeObject(forKey: key)
        }
    }

    /// Whether the shield is on for this launch.
    var isEnabled: Bool { true }

    /// The recording cover appears only while the shield is not protecting the pixels (owner decision K4).
    var coverMode: CaptureCoverMode { .fallback }
}

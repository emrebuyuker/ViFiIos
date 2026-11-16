import Foundation

/// The screen-capture shield's switch for this launch.
///
/// The shield has no remote setting: the app never changes its behaviour from a server flag (owner decision,
/// 16 November 2026, App Review). It is on in every Release launch; it fails open only on its own, when the OS build
/// offers no shield or `CaptureShieldCrashGuard` trips. Debug `-ViFiCaptureShieldOff` turns it off for screenshots.
final class CaptureShieldSwitch {
    /// Keys a pre-release build stored for the removed remote switch; cleared so nothing stale is left behind.
    static let retiredKeys = ["captureShield.remoteEnabled", "captureShield.remoteCoverMode"]

    /// `true` when this launch forced the shield off locally (Debug `-ViFiCaptureShieldOff`).
    let isForcedOff: Bool

    /// - Parameters:
    ///   - forcedOff: Switches the shield off for this launch (Debug only).
    ///   - defaults: Where the retired remote-switch keys are cleared.
    init(forcedOff: Bool = false, defaults: UserDefaults = .standard) {
        isForcedOff = forcedOff
        for key in Self.retiredKeys {
            defaults.removeObject(forKey: key)
        }
    }

    /// Whether the shield is on for this launch.
    var isEnabled: Bool { !isForcedOff }

    /// The recording cover appears only while the shield is not protecting the pixels (owner decision K4).
    var coverMode: CaptureCoverMode { .fallback }
}

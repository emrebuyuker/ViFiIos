import ObjectiveC
import os
import UIKit

/// Excludes a layer, and in captures its whole subtree, from screenshots and screen recordings.
///
/// Mechanism (Telegram-iOS since 2023-11-23, Signal-iOS since 2026-09-16): a donor `UITextField` that
/// never enters a window owns an internal canvas view whose layer UIKit flags when `isSecureTextEntry`
/// changes. The canvas view's `layer` storage is rebound by KVC to the target layer for one
/// `false -> true` toggle, so UIKit writes its flag onto the target. Nothing is re-parented.
///
/// Private surface: the class-name substring `TextLayoutCanvasView` and KVC on the key `layer`
/// (which reaches UIView's `_layer` ivar). No private selector is called and no private CALayer key
/// is named. When the canvas cannot be found or the KVC preconditions fail, `isAvailable` is `false`
/// and the caller decides (ViFi fails open: show the page, log a fault, show the recording cover on capture).
/// `isAvailable` is also `false` once `CaptureShieldCrashGuard` has seen two launches in a row die inside a swap on
/// this app build and iOS version.
///
/// Rules: the canvas is found by class name, never by subview index (index 0 is an unflagged
/// `_UITouchPassthroughView` since iOS 17); the private layer mask key is never written directly.
final class CaptureShield {
    static let shared = CaptureShield(crashGuard: .live())

    /// `false` when protection cannot be applied on this OS build. Read it before trusting the shield.
    let isAvailable: Bool

    /// This launch's switch (`CaptureShieldRemoteSwitch.isEnabled`: remote `config/captureProtection/ios.enabled`
    /// and Debug `-ViFiCaptureShieldOff`). Set once by `AppEnvironment` before any exam page is shown; `false` shows
    /// pages unprotected (fail open) and lets the recording cover take over.
    static var isSwitchedOn = true

    /// Whether exam pixels are protected this launch: the shield works on this OS build and is switched on.
    var isActive: Bool { isAvailable && Self.isSwitchedOn }

    private let donorField = UITextField()
    private let donorCanvas: UIView?
    private let crashGuard: CaptureShieldCrashGuard

    /// Internal for tests; the app uses `shared`.
    init(crashGuard: CaptureShieldCrashGuard) {
        self.crashGuard = crashGuard
        donorCanvas = donorField.subviews.first { view in
            String(describing: type(of: view)).contains("TextLayoutCanvasView")
        }
        // KVC on "layer" must reach UIView's private ivar, never a setter that might behave differently.
        let kvcReachesIvar = class_getInstanceVariable(UIView.self, "_layer") != nil
            && UIView.accessInstanceVariablesDirectly
        let canSwap = donorCanvas != nil && kvcReachesIvar
        isAvailable = canSwap && !crashGuard.isTripped
        if !canSwap {
            Logger.app.fault("Capture shield unavailable on this OS build; exam pages are capturable")
        } else if crashGuard.didTripThisLaunch {
            Logger.app.fault(
                "Capture shield crash guard tripped for \(crashGuard.stamp, privacy: .public); exam pages are capturable"
            )
        } else if crashGuard.isTripped {
            Logger.app.error("Capture shield off by the crash guard for \(crashGuard.stamp, privacy: .public)")
        }
        // Main queue, so the closure runs on the main actor; the observer lives as long as the process.
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [crashGuard] _ in
            MainActor.assumeIsolated { crashGuard.applicationDidEnterBackground() }
        }
    }

    /// Applies (`true`) or removes (`false`) the capture exclusion on `view`'s own layer.
    /// Returns `false` when the shield is unavailable or the swap left the view in a bad state.
    @discardableResult
    func setProtected(_ isProtected: Bool, on view: UIView) -> Bool {
        guard isAvailable, let donorCanvas else { return false }
        let targetLayer = view.layer
        let canvasLayer = donorCanvas.layer
        crashGuard.run(kind: "\(type(of: view))|\(isProtected)") {
            donorCanvas.setValue(targetLayer, forKey: "layer")
            // UIKit writes the flag only on an actual change of `isSecureTextEntry`, hence two assignments.
            donorField.isSecureTextEntry = !isProtected
            donorField.isSecureTextEntry = isProtected
            // Hand the canvas its own layer back before anything else touches it.
            donorCanvas.setValue(canvasLayer, forKey: "layer")
        }
        // Signal's guard: if UIKit re-pointed the delegate, the view would stop drawing and laying out.
        guard targetLayer.delegate === view else {
            Logger.app.fault("Capture shield swap re-pointed the layer delegate; protection not trusted")
            return false
        }
        return true
    }
}

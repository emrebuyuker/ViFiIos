import UIKit

#if DEBUG
/// Debug-only, public-API check that a shielded view's pixels are left out of an in-process capture
/// (`-ViFiCaptureShieldSelfTest`; `CaptureShieldedView` runs it and publishes the result for UI tests).
///
/// `drawHierarchy(in:afterScreenUpdates:)` goes through the render server's snapshot path, which honours the capture
/// exclusion (measured on iOS 17.0 and 26.5 simulators: 0.59–0.67 for a flagged page, 0.000 for an unflagged label),
/// while `CALayer.render(in:)` draws on the CPU and ignores it. A difference above `threshold` means the flagged
/// subtree was left out. It is a hierarchy / regression check, **not** proof for device screenshots or recordings,
/// and it never ships in Release. Measure the flagged view itself (or an ancestor), never one of its subviews.
enum CaptureShieldSelfTest {
    /// The result published on `exam.shield.selfTest`'s `accessibilityValue`.
    enum Outcome: String {
        case pending
        /// The capture render left the content out.
        case verified
        /// The content was flagged but the capture render still drew it (or `render(in:)` skipped it on iOS 26).
        case unverified
        /// The shield is unavailable or switched off for this launch: nothing was flagged.
        case off
    }

    /// Whether this launch runs the self-test.
    static let isEnabled = ProcessInfo.processInfo.arguments.contains(LaunchArgument.captureShieldSelfTest)

    /// Above this mean channel difference the content counts as excluded from captures.
    static let threshold = 0.02

    /// Mean absolute per-channel difference (0...1) between the capture-honouring render and the plain render.
    /// Returns 0 when the view is not on screen or has no size (a real `UIApplication` window is required).
    static func captureDifference(of view: UIView) -> Double {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0, view.window != nil else { return 0 }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let captured = renderer.image { _ in
            _ = view.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        let plain = renderer.image { context in
            view.layer.render(in: context.cgContext)
        }
        guard let lhs = rgba(captured), let rhs = rgba(plain), lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var total = 0
        for index in lhs.indices {
            total += abs(Int(lhs[index]) - Int(rhs[index]))
        }
        return Double(total) / Double(lhs.count * 255)
    }

    private static func rgba(_ image: UIImage) -> [UInt8]? {
        guard let cgImage = image.cgImage else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? pixels : nil
    }
}
#endif

#if DEBUG
/// Runs `CaptureShieldSelfTest` for one `CaptureShieldedView` and publishes the outcome on a 1-point accessibility
/// element (`exam.shield.selfTest`, value `pending` / `verified` / `unverified` / `off`), which UI tests read.
/// Non-generic on purpose, so the generic container only stores an optional reference to it.
final class CaptureShieldSelfTestProbe {
    private let marker = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    private var task: Task<Void, Never>?

    init(container: UIView) {
        marker.isUserInteractionEnabled = false
        marker.isAccessibilityElement = true
        marker.accessibilityIdentifier = "exam.shield.selfTest"
        marker.accessibilityLabel = "capture shield self-test"
        marker.accessibilityValue = CaptureShieldSelfTest.Outcome.pending.rawValue
        container.addSubview(marker)
    }

    /// Measures `content` once it is on screen; retries a few times while a page or PDF is still loading.
    func start(content: UIView, isShielded: Bool) {
        guard task == nil else { return }
        guard isShielded else {
            publish(.off)
            return
        }
        task = Task { [weak self, weak content] in
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(700))
                guard let self, let content else { return }
                let difference = CaptureShieldSelfTest.captureDifference(of: content)
                if difference > CaptureShieldSelfTest.threshold {
                    self.publish(.verified)
                    return
                }
            }
            self?.publish(.unverified)
        }
    }

    private func publish(_ outcome: CaptureShieldSelfTest.Outcome) {
        marker.accessibilityValue = outcome.rawValue
    }
}
#endif

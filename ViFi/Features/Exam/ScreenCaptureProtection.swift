import SwiftUI
import UIKit

extension View {
    /// Covers the exam content while the screen is being recorded or mirrored, and flashes a brief notice when
    /// a screenshot is taken. Pair it with the secure host, which keeps the pixels out of the capture itself;
    /// this adds a visible signal and a reliable fallback.
    func screenCaptureProtection() -> some View {
        modifier(ScreenCaptureProtectionModifier())
    }
}

private struct ScreenCaptureProtectionModifier: ViewModifier {
    @State private var isCaptured = false
    @State private var isShowingScreenshotNotice = false

    func body(content: Content) -> some View {
        content
            .background {
                // A zero-size reader that reports capture state and screenshots without affecting layout.
                CaptureStateReader(
                    onCaptureChange: { captured in
                        Task { @MainActor in isCaptured = captured }
                    },
                    onScreenshot: { flashScreenshotNotice() }
                )
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
            .overlay {
                if isCaptured {
                    CaptureCoverView()
                        .transition(.opacity)
                }
            }
            .overlay(alignment: .top) {
                if isShowingScreenshotNotice {
                    ScreenshotNoticeView()
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isCaptured)
            .animation(.easeInOut(duration: 0.25), value: isShowingScreenshotNotice)
    }

    private func flashScreenshotNotice() {
        isShowingScreenshotNotice = true
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            isShowingScreenshotNotice = false
        }
    }
}

// MARK: - Capture state

/// Reports screen recording / mirroring (via the `sceneCaptureState` trait, iOS 17+) and screenshots, without
/// the deprecated `UIScreen.isCaptured`. Backed by a hidden `UIView`.
private struct CaptureStateReader: UIViewRepresentable {
    var onCaptureChange: (Bool) -> Void
    var onScreenshot: () -> Void

    func makeUIView(context: Context) -> CaptureStateUIView {
        let view = CaptureStateUIView()
        view.onCaptureChange = onCaptureChange
        view.onScreenshot = onScreenshot
        return view
    }

    func updateUIView(_ uiView: CaptureStateUIView, context: Context) {
        uiView.onCaptureChange = onCaptureChange
        uiView.onScreenshot = onScreenshot
    }
}

private final class CaptureStateUIView: UIView {
    var onCaptureChange: ((Bool) -> Void)?
    var onScreenshot: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        registerForTraitChanges([UITraitSceneCaptureState.self]) { (view: CaptureStateUIView, _) in
            view.reportCaptureState()
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenshotTaken),
            name: UIApplication.userDidTakeScreenshotNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportCaptureState()
    }

    @objc private func screenshotTaken() {
        onScreenshot?()
    }

    private func reportCaptureState() {
        onCaptureChange?(traitCollection.sceneCaptureState == .active)
    }
}

// MARK: - Overlays

/// An opaque cover shown over the exam while the screen is recorded or mirrored.
private struct CaptureCoverView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "eye.slash.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Ekran kaydı sırasında sınav içeriği gizlenir")
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
            Text("Kaydı durdurduğunda içerik yeniden görünür.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("exam.captureCover")
    }
}

/// A brief notice that a screenshot was taken; the content is protected, so this only informs the user.
private struct ScreenshotNoticeView: View {
    var body: some View {
        Label("Sınav içeriği korumalıdır", systemImage: "lock.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.85), in: .capsule)
            .accessibilityIdentifier("exam.screenshotNotice")
    }
}

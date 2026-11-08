import OSLog
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

/// How the capture cover decides to appear. `fallback`: only when the capture shield is not protecting the pixels
/// (the page stays visible on the device while recording, owner decision K4). `always`: on every recording or
/// mirroring. A remote switch (`coverMode`) will drive this later; until then the environment default applies.
enum CaptureCoverMode: Sendable {
    case fallback
    case always
}

/// The single gate that decides whether the capture cover is shown. Pure, so it is tested without UIKit.
enum CaptureCoverPolicy {
    static func shouldCover(isCaptured: Bool, mode: CaptureCoverMode, shieldIsActive: Bool) -> Bool {
        guard isCaptured else { return false }
        switch mode {
        case .always: return true
        case .fallback: return !shieldIsActive
        }
    }
}

extension EnvironmentValues {
    /// Whether the cover appears on every capture or only when the shield is not active. Defaults to `fallback`.
    @Entry var captureCoverMode: CaptureCoverMode = .fallback
    /// Whether the capture shield is currently protecting the exam pixels. Defaults to `false` (no shield wired
    /// yet), so today every capture is covered; the shield integration sets this from `CaptureShield.isAvailable`.
    @Entry var captureShieldIsActive = false
}

private struct ScreenCaptureProtectionModifier: ViewModifier {
    @Environment(\.captureCoverMode) private var coverMode
    @Environment(\.captureShieldIsActive) private var shieldIsActive
    @State private var isCaptured = false
    @State private var isShowingScreenshotNotice = false

    func body(content: Content) -> some View {
        content
            .background {
                // A zero-size reader that reports capture state and screenshots without affecting layout.
                CaptureStateReader(
                    onCaptureChange: { captured in isCaptured = captured },
                    onScreenshot: { flashScreenshotNotice() }
                )
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
            .overlay {
                // No transition or animation: the cover must be in place in the same frame the signal arrives.
                if CaptureCoverPolicy.shouldCover(isCaptured: isCaptured, mode: coverMode, shieldIsActive: shieldIsActive) {
                    CaptureCoverView()
                }
            }
            .overlay(alignment: .top) {
                if isShowingScreenshotNotice {
                    ScreenshotNoticeView()
                        .padding(.top, 10)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
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

/// Reports screen recording / mirroring from two signals, because neither alone is reliable on every iOS
/// build: the scene's `sceneCaptureState` trait and `UIScreen.capturedDidChangeNotification` (read from the
/// window's own screen, never `UIScreen.main`). Also reports screenshots. Backed by a hidden `UIView`.
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
    private var lastReported: Bool?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        registerForTraitChanges([UITraitSceneCaptureState.self]) { (view: CaptureStateUIView, _) in
            view.reportCaptureState(source: "trait")
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenshotTaken),
            name: UIApplication.userDidTakeScreenshotNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenCaptureChanged),
            name: UIScreen.capturedDidChangeNotification,
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
        #if DEBUG
        CaptureDebug.log("didMoveToWindow window=\(window != nil)")
        #endif
        reportCaptureState(source: "didMoveToWindow")
    }

    @objc private func screenshotTaken() {
        onScreenshot?()
    }

    @objc private func screenCaptureChanged() {
        reportCaptureState(source: "screenNotification")
    }

    private func reportCaptureState(source: String) {
        // Either signal alone is enough to cover; the window's screen is nil until the view is attached.
        var isCaptured = traitCollection.sceneCaptureState == .active || window?.screen.isCaptured == true
        #if DEBUG
        // The trait cannot be overridden on a view (the scene owns it), so the simulation forces the result.
        if CaptureDebug.simulatesCapture { isCaptured = true }
        #endif
        #if DEBUG
        CaptureDebug.log("\(source) trait=\(traitCollection.sceneCaptureState.rawValue) "
            + "screen=\(window?.screen.isCaptured.description ?? "nil") -> captured=\(isCaptured)")
        #endif
        guard isCaptured != lastReported else { return }
        lastReported = isCaptured
        onCaptureChange?(isCaptured)
    }
}

#if DEBUG
/// Debug-only capture diagnostics: `-ViFiCaptureLog` writes every signal to OSLog (`Logger.app`) with a
/// timestamp; `-ViFiSimulateCapture` forces the captured state on so the cover can be tested without recording.
enum CaptureDebug {
    static let simulatesCapture = ProcessInfo.processInfo.arguments.contains(LaunchArgument.simulateCapture)
    static let logsSignals = ProcessInfo.processInfo.arguments.contains(LaunchArgument.captureLog)

    static func log(_ message: String) {
        guard logsSignals else { return }
        let stamp = Date.now.formatted(.iso8601.time(includingFractionalSeconds: true))
        Logger.app.notice("[CaptureLog \(stamp, privacy: .public)] \(message, privacy: .public)")
    }
}
#endif

// MARK: - Overlays

/// An opaque cover shown over the exam while the screen is recorded or mirrored.
private struct CaptureCoverView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "eye.slash.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Ekran kaydı ya da yansıtma sırasında sınav içeriği gizlenir")
                .font(.headline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
            Text("Kaydı ya da yansıtmayı durdurduğunda içerik yeniden görünür.")
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

/// A brief notice that a screenshot was taken. It makes no promise about what the capture contains.
private struct ScreenshotNoticeView: View {
    var body: some View {
        Label("Ekran görüntüsünde sınav içeriği görünmeyebilir", systemImage: "camera.viewfinder")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.black.opacity(0.85), in: .capsule)
            .accessibilityIdentifier("exam.screenshotNotice")
    }
}

// MARK: - App switcher cover

extension View {
    /// An opaque branded cover while the scene is not active, so no screen (exam content included) appears in the
    /// multitasking snapshot. Apply it at the root and at every sheet / full-screen cover root: a presented
    /// controller is its own hierarchy, so the root's cover does not reach it.
    func appSwitcherCover() -> some View {
        modifier(AppSwitcherCoverModifier())
    }
}

private struct AppSwitcherCoverModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.overlay {
            // No animation: the snapshot is taken the instant the app becomes inactive, so the cover must be
            // in place immediately. (The condition stays as it was until K15 is verified on a device.)
            if scenePhase != .active {
                AppSwitcherCoverView()
            }
        }
    }
}

private struct AppSwitcherCoverView: View {
    @ScaledMetric(relativeTo: .largeTitle) private var logoSize: CGFloat = 96

    var body: some View {
        ZStack {
            Color(.systemBackground)
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: min(logoSize, 128), height: min(logoSize, 128))
                .clipShape(.rect(cornerRadius: min(logoSize, 128) * 0.225, style: .continuous))
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

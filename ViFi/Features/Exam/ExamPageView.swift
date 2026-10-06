import OSLog
import SwiftUI

/// One page of an image exam, shown as a paper-like card with a "Sayfa 1 / 3" caption.
///
/// The page is downloaded and downsampled for the card's width on screen. An A4 placeholder
/// keeps the layout stable while it loads, and a failed page offers an inline retry.
/// Tapping the card opens the page (`onOpen`), or retries after a failure.
struct ExamPageView: View {
    let url: URL
    /// 1-based.
    let pageNumber: Int
    let pageCount: Int
    /// Called with each image shown, so a full-screen viewer can start from it.
    var onLoad: (UIImage) -> Void = { _ in }
    var onOpen: () -> Void = {}

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.displayScale) private var displayScale
    @State private var phase: Phase = .loading
    @State private var cardWidth: CGFloat = 0
    @State private var attempt = 0

    var body: some View {
        Button(action: primaryAction) {
            VStack(spacing: 10) {
                card
                Text("Sayfa \(pageNumber) / \(pageCount)")
                    .font(.footnote.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(PageCardButtonStyle())
        .accessibilityLabel(pageAccessibilityLabel)
        .accessibilityHint(pageAccessibilityHint)
        .task(id: loadRequest) { [request = loadRequest] in
            await loadImage(for: request)
        }
    }

    // MARK: - Content

    private var card: some View {
        ZStack {
            switch phase {
            case let .loaded(image, _):
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity)
            case .loading:
                placeholder {
                    ProgressView()
                        .controlSize(.large)
                }
            case let .failed(message):
                placeholder {
                    PageFailureView(message: message)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(cardShape)
        .background {
            // The shadow is cast by a plain shape, which is cheaper to render than the image.
            cardShape
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        }
        .overlay {
            // A hairline keeps the card's edge visible in Dark Mode, where the shadow disappears.
            cardShape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            cardWidth = width
        }
        .animation(.easeOut(duration: 0.25), value: phase.isLoaded)
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
    }

    /// An empty A4 page with `content` in the middle; grows taller when `content` needs more room
    /// (an error message at large text sizes) instead of being clipped by the card.
    private func placeholder(@ViewBuilder content: () -> some View) -> some View {
        ZStack {
            Color.clear
                .aspectRatio(Layout.a4AspectRatio, contentMode: .fit)
            content()
        }
    }

    // MARK: - Actions & accessibility

    private func primaryAction() {
        if phase.isFailed {
            attempt += 1
        } else {
            onOpen()
        }
    }

    private var pageAccessibilityLabel: Text {
        phase.isFailed
            ? Text("Sayfa \(pageNumber) / \(pageCount), yüklenemedi")
            : Text("Sayfa \(pageNumber) / \(pageCount)")
    }

    private var pageAccessibilityHint: Text {
        phase.isFailed ? Text("Sayfayı yeniden yükler.") : Text("Sayfayı tam ekran açar.")
    }

    // MARK: - Loading

    private var loadRequest: LoadRequest {
        LoadRequest(url: url, pixelSize: targetPixelSize, attempt: attempt)
    }

    /// The longest side to decode, in pixels: the card's width at A4 height on this screen, rounded
    /// up to a step of 256 so that small width changes do not trigger another decode.
    private var targetPixelSize: CGFloat {
        guard cardWidth > 0 else { return 0 }
        let pixels = cardWidth * displayScale / Layout.a4AspectRatio
        return (pixels / Layout.pixelSizeStep).rounded(.up) * Layout.pixelSizeStep
    }

    private func loadImage(for request: LoadRequest) async {
        // Wait for the first layout pass; keep an image that is already sharp enough.
        guard request.pixelSize > 0 else { return }
        if let loadedSize = phase.loadedPixelSize, loadedSize >= request.pixelSize { return }

        // A larger card (rotation, iPad resize) swaps in a sharper image without a placeholder.
        let isUpgrade = phase.isLoaded
        if !isUpgrade {
            phase = .loading
        }
        do {
            let image = try await environment.fileLoader.image(from: request.url, maxPixelSize: request.pixelSize)
            // A newer request may already have shown a larger image.
            if let loadedSize = phase.loadedPixelSize, loadedSize >= request.pixelSize { return }
            phase = .loaded(image, pixelSize: request.pixelSize)
            onLoad(image)
        } catch {
            // Scrolling away cancels the download; it restarts when the page appears again.
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            let reason = error.localizedDescription
            Logger.files.error("Page \(pageNumber) failed to load: \(reason, privacy: .public)")
            if !isUpgrade {
                phase = .failed(message: error.userMessage)
            }
        }
    }
}

// MARK: - Supporting types

private extension ExamPageView {
    enum Phase {
        case loading
        case loaded(UIImage, pixelSize: CGFloat)
        case failed(message: String)

        var isLoaded: Bool { loadedPixelSize != nil }

        var isFailed: Bool {
            if case .failed = self { true } else { false }
        }

        var loadedPixelSize: CGFloat? {
            if case let .loaded(_, pixelSize) = self { pixelSize } else { nil }
        }
    }

    struct LoadRequest: Hashable {
        let url: URL
        let pixelSize: CGFloat
        let attempt: Int
    }

    enum Layout {
        static let cornerRadius: CGFloat = 12
        /// Width / height of an A4 sheet, the shape of most scanned exam pages.
        static let a4AspectRatio: CGFloat = 1 / 2.squareRoot()
        static let pixelSizeStep: CGFloat = 256
    }
}

/// The content of a page that could not be loaded. The whole card is the retry button.
private struct PageFailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Text("Sayfa yüklenemedi")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Label("Tekrar Dene", systemImage: "arrow.clockwise")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.15), in: .capsule)
        }
        .padding(24)
    }
}

/// A gentle press feedback for the page cards.
private struct PageCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

#if DEBUG
#Preview {
    ScrollView {
        VStack(spacing: 24) {
            ForEach(Array(ExamPreviewFixtures.imagesDocument.fileURLs.enumerated()), id: \.offset) { index, url in
                ExamPageView(url: url, pageNumber: index + 1, pageCount: 3)
            }
        }
        .padding()
    }
    .background(Color(.systemGroupedBackground))
    .environment(AppEnvironment.mock())
}
#endif

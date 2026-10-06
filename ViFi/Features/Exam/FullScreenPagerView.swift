import OSLog
import SwiftUI

/// The pages of an image exam full screen on black: swipe between pages, pinch or double-tap to zoom,
/// tap to hide the controls, share the current page. Presented with `.fullScreenCover`.
struct FullScreenPagerView: View {
    let document: ExamDocument
    /// Images already shown in the page list, displayed until the sharper full-screen version loads.
    let previews: [Int: UIImage]
    /// Called when the user starts sharing a page.
    let onShare: () -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled
    @State private var selection: Int
    @State private var isChromeHidden = false
    @State private var screenLength: CGFloat = 0
    @State private var shareFiles: [Int: URL] = [:]
    @State private var failedShareFiles: Set<Int> = []
    @State private var shareAttempt = 0

    init(
        document: ExamDocument,
        initialPage: Int = 0,
        previews: [Int: UIImage] = [:],
        onShare: @escaping () -> Void = {}
    ) {
        self.document = document
        self.previews = previews
        self.onShare = onShare
        let lastPage = max(document.fileURLs.count - 1, 0)
        _selection = State(initialValue: min(max(initialPage, 0), lastPage))
    }

    var body: some View {
        pager
            .background(Color.black.ignoresSafeArea())
            .overlay(alignment: .top) {
                if showsChrome {
                    topBar
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                max(proxy.size.width, proxy.size.height)
            } action: { length in
                screenLength = length
            }
            .statusBarHidden()
            .persistentSystemOverlays(showsChrome ? .automatic : .hidden)
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("viewer.fullscreen")
            .accessibilityAction(.escape) { dismiss() }
            .onAppear { environment.analytics.track(.screenView(name: "ExamViewer")) }
            .task(id: ShareFileRequest(page: selection, attempt: shareAttempt)) { [page = selection] in
                await prepareShareFile(forPage: page)
            }
    }

    // MARK: - Pager

    private var pageCount: Int { document.fileURLs.count }

    /// VoiceOver users always get the controls: a hidden close button would trap them.
    private var showsChrome: Bool { !isChromeHidden || isVoiceOverEnabled }

    /// Twice the screen's longest side in pixels, so zoomed text stays sharp, capped to bound memory.
    /// The longest side does not change on rotation, so rotating never triggers another decode.
    private var maxPixelSize: CGFloat {
        guard screenLength > 0 else { return 0 }
        let pixels = screenLength * displayScale * 2
        return min((pixels / 256).rounded(.up) * 256, Self.maxDecodedPixelSize)
    }

    private static let maxDecodedPixelSize: CGFloat = 4096

    private var pager: some View {
        TabView(selection: $selection) {
            ForEach(document.fileURLs.indices, id: \.self) { index in
                ZoomablePage(
                    url: document.fileURLs[index],
                    pageNumber: index + 1,
                    preview: previews[index],
                    maxPixelSize: maxPixelSize,
                    isCurrent: index == selection,
                    onSingleTap: toggleChrome
                )
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
    }

    private func toggleChrome() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isChromeHidden.toggle()
        }
    }

    // MARK: - Controls

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .viewerControlLabel()
            }
            .viewerSurface(in: Circle(), interactive: true)
            .accessibilityLabel("Kapat")
            .accessibilityShowsLargeContentViewer()
            .accessibilityIdentifier("viewer.close")

            Spacer(minLength: 0)

            Text("\(selection + 1) / \(pageCount)")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .padding(.horizontal, 16)
                .frame(minHeight: 36)
                .viewerSurface(in: Capsule())
                .animation(.snappy, value: selection)
                .accessibilityShowsLargeContentViewer()
                .accessibilityIdentifier("viewer.counter")

            Spacer(minLength: 0)

            shareControl
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        // The glass controls are fixed 44 pt circles; larger text is offered via the large content viewer.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    /// A `ShareLink` once the current page is saved as a file; a spinner (or a retry after an error) before.
    @ViewBuilder
    private var shareControl: some View {
        Group {
            if let file = shareFiles[selection] {
                ShareLink(item: file) {
                    Image(systemName: "square.and.arrow.up")
                        .viewerControlLabel()
                }
                // ShareLink reports no completion, so this records the intent to share.
                .simultaneousGesture(TapGesture().onEnded(onShare))
                .accessibilityAddTraits(.isButton)
            } else {
                let hasFailed = failedShareFiles.contains(selection)
                Button {
                    shareAttempt += 1
                } label: {
                    if hasFailed {
                        Image(systemName: "square.and.arrow.up")
                            .viewerControlLabel()
                    } else {
                        ProgressView()
                            .tint(.white)
                            .frame(width: 44, height: 44)
                    }
                }
                .disabled(!hasFailed)
            }
        }
        .viewerSurface(in: Circle(), interactive: true)
        .accessibilityLabel("Sayfayı paylaş")
        .accessibilityIdentifier("viewer.share")
    }

    // MARK: - Sharing

    private func prepareShareFile(forPage page: Int) async {
        guard shareFiles[page] == nil, document.fileURLs.indices.contains(page) else { return }
        failedShareFiles.remove(page)
        do {
            shareFiles[page] = try await environment.fileLoader.localFile(
                from: document.fileURLs[page],
                fileName: document.pageFileName(at: page)
            )
        } catch {
            // Swiping on cancels the preparation; it restarts when the user comes back to the page.
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            Logger.files.error("Preparing page \(page + 1) for sharing failed: \(error.localizedDescription, privacy: .public)")
            failedShareFiles.insert(page)
        }
    }
}

// MARK: - Page

/// One page of the pager: shows the list preview at once, then a sharper, zoomable version.
/// The sharp image is released when the page scrolls off screen, so only visible pages hold one.
private struct ZoomablePage: View {
    let url: URL
    let pageNumber: Int
    let preview: UIImage?
    let maxPixelSize: CGFloat
    let isCurrent: Bool
    let onSingleTap: () -> Void

    @Environment(AppEnvironment.self) private var environment
    @State private var image: UIImage?
    @State private var loadedPixelSize: CGFloat = 0
    @State private var errorMessage: String?
    @State private var attempt = 0

    var body: some View {
        ZStack {
            if let displayed = image ?? preview {
                ZoomableImageView(
                    image: displayed,
                    isActive: isCurrent,
                    imageDescription: String(localized: "Sayfa \(pageNumber)"),
                    onSingleTap: onSingleTap
                )
            } else {
                // Same tap target as an image page, so hidden controls can always be brought back.
                // The retry button inside `failure` still wins over this ancestor gesture. Not a button for
                // VoiceOver: the controls are never hidden while it runs, so there is nothing to toggle.
                // swiftlint:disable:next accessibility_trait_for_button
                Group {
                    if let errorMessage {
                        failure(message: errorMessage)
                    } else {
                        ProgressView()
                            .controlSize(.large)
                            .tint(.white)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
                .onTapGesture(perform: onSingleTap)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .task(id: LoadRequest(url: url, pixelSize: maxPixelSize, attempt: attempt)) { [maxPixelSize] in
            await loadImage(maxPixelSize: maxPixelSize)
        }
        .onDisappear(perform: releaseImage)
    }

    private func failure(message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Sayfa yüklenemedi")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                attempt += 1
            } label: {
                Text("Tekrar Dene")
                    .foregroundStyle(.black)
            }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
        .padding(32)
        .frame(maxWidth: 420)
    }

    private func loadImage(maxPixelSize: CGFloat) async {
        guard maxPixelSize > 0, image == nil || loadedPixelSize < maxPixelSize else { return }
        errorMessage = nil
        do {
            let loaded = try await environment.fileLoader.image(from: url, maxPixelSize: maxPixelSize)
            // Cancelled because the page left the screen: do not keep a large image for it.
            guard !Task.isCancelled else { return }
            image = loaded
            loadedPixelSize = maxPixelSize
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            Logger.files.error("Full-screen page \(pageNumber) failed: \(error.localizedDescription, privacy: .public)")
            // With a preview on screen the page stays readable; only an empty page shows the error.
            errorMessage = error.userMessage
        }
    }

    private func releaseImage() {
        image = nil
        loadedPixelSize = 0
    }
}

private struct LoadRequest: Hashable {
    let url: URL
    let pixelSize: CGFloat
    let attempt: Int
}

private struct ShareFileRequest: Hashable {
    let page: Int
    let attempt: Int
}

// MARK: - Viewer chrome

extension View {
    /// A translucent floating surface for controls over content: Liquid Glass on iOS 26, a material before.
    /// Shared by the exam viewers.
    @ViewBuilder
    func viewerSurface(in shape: some Shape, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            background(.regularMaterial, in: shape)
        }
    }
}

private extension View {
    /// The 44 pt icon of a round viewer control.
    func viewerControlLabel() -> some View {
        font(.body.weight(.semibold))
            .frame(width: 44, height: 44)
            .contentShape(.circle)
    }
}

#if DEBUG
#Preview {
    FullScreenPagerView(document: ExamPreviewFixtures.imagesDocument, initialPage: 1)
        .environment(AppEnvironment.mock())
        .environment(Router())
}
#endif

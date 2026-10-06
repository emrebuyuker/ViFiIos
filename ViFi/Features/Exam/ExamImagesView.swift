import OSLog
import SwiftUI
import UIKit

/// The viewer of an image exam: its pages as cards in a vertical scroll, a full-screen zoomable
/// pager on tap, and a toolbar action that shares every page as a file.
struct ExamImagesView: View {
    let path: ArchivePath

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        ExamImagesScreen(
            viewModel: ExamDocumentViewModel(
                path: path,
                repository: environment.repository,
                recents: environment.recents,
                analytics: environment.analytics
            )
        )
    }
}

/// Owns the view model; `@State` keeps the first instance it is given for the screen's lifetime.
private struct ExamImagesScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(Router.self) private var router
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var viewModel: ExamDocumentViewModel
    @State private var loadAttempt = 0
    /// Page images already decoded by the list, handed to the full-screen viewer.
    @State private var pagePreviews: [Int: UIImage] = [:]
    @State private var openedPage: OpenedPage?
    @State private var shareRequest: UUID?
    @State private var shareProgress: ShareProgress?
    @State private var sharePayload: SharePayload?
    @State private var shareErrorMessage: String?

    init(viewModel: ExamDocumentViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        content
            // One background for every state, behind the bars too, so nothing flashes white.
            .background(Color(.systemGroupedBackground))
            .navigationTitle(viewModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    shareButton
                }
            }
            .task(id: loadAttempt) {
                await viewModel.loadIfNeeded()
            }
            .onAppear { environment.analytics.track(.screenView(name: "ExamImages")) }
            .onChange(of: viewModel.document?.kind) { _, kind in
                redirectIfKindChanged(kind)
            }
            .task(id: shareRequest) { [request = shareRequest] in
                await prepareShare(for: request)
            }
            .fullScreenCover(item: $openedPage) { page in
                if let document = viewModel.document {
                    FullScreenPagerView(
                        document: document,
                        initialPage: page.index,
                        previews: pagePreviews,
                        onShare: { viewModel.recordShare() }
                    )
                    .environment(environment)
                }
            }
            .background {
                ActivitySheetPresenter(payload: $sharePayload) { completed in
                    if completed {
                        viewModel.recordShare()
                    }
                }
            }
            .alert(
                "Paylaşım hazırlanamadı",
                isPresented: Binding(
                    get: { shareErrorMessage != nil },
                    set: { if !$0 { shareErrorMessage = nil } }
                ),
                presenting: shareErrorMessage
            ) { _ in
                Button("Tamam", role: .cancel) {}
            } message: { message in
                Text(message)
            }
    }

    // MARK: - Routing

    /// The route's kind comes from a list summary or a stored recent exam. If the exam's files have
    /// changed kind since, replace this screen with the matching viewer.
    private func redirectIfKindChanged(_ kind: ExamKind?) {
        guard let kind, kind != .images, router.path.last == .exam(viewModel.path, .images) else { return }
        router.path[router.path.count - 1] = .exam(viewModel.path, kind)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            LoadingStateView()
        case let .failed(message):
            ErrorStateView(message: message) {
                loadAttempt += 1
            }
        case let .loaded(document) where document.kind != .images:
            LoadingStateView()
        case let .loaded(document) where document.fileURLs.isEmpty:
            EmptyStateView(title: "Bu sınavda sayfa yok", systemImage: "doc.text")
        case let .loaded(document):
            pageList(of: document)
        }
    }

    private func pageList(of document: ExamDocument) -> some View {
        let pageCount = document.fileURLs.count
        return ScrollView {
            LazyVStack(spacing: Layout.pageSpacing) {
                ExamContextHeader(subtitle: viewModel.subtitle, pageCount: pageCount)

                ForEach(document.fileURLs.indices, id: \.self) { index in
                    ExamPageView(
                        url: document.fileURLs[index],
                        pageNumber: index + 1,
                        pageCount: pageCount,
                        onLoad: { image in pagePreviews[index] = image },
                        onOpen: { openedPage = OpenedPage(index: index) }
                    )
                    .accessibilityIdentifier("exam.page.\(index)")
                }
            }
            .frame(maxWidth: Layout.readableWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, horizontalSizeClass == .regular ? 32 : 16)
            .padding(.vertical, 20)
        }
        .background(Color(.systemGroupedBackground))
        .accessibilityIdentifier("exam.images")
        .overlay(alignment: .bottom) {
            if let shareProgress {
                SharePreparationBanner(progress: shareProgress, cancel: cancelShare)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy, value: shareProgress == nil)
    }

    private var shareButton: some View {
        Button {
            shareRequest = UUID()
        } label: {
            Label("Paylaş", systemImage: "square.and.arrow.up")
        }
        .disabled(!canShare)
        .accessibilityLabel("Tüm sayfaları paylaş")
        .accessibilityIdentifier("exam.share")
    }

    // MARK: - Sharing

    private var canShare: Bool {
        guard let document = viewModel.document else { return false }
        return !document.fileURLs.isEmpty && shareProgress == nil
    }

    /// Saves every page as "<exam> - Sayfa N.jpg", then opens the share sheet.
    /// Runs as the `.task` of `shareRequest`, so cancelling or leaving the screen stops it.
    private func prepareShare(for request: UUID?) async {
        guard let request, let document = viewModel.document else { return }
        let total = document.fileURLs.count
        shareProgress = ShareProgress(completed: 0, total: total)
        defer { finishShare(request) }

        do {
            var files: [URL] = []
            for (index, url) in document.fileURLs.enumerated() {
                let file = try await environment.fileLoader.localFile(from: url, fileName: document.pageFileName(at: index))
                // A cancelled request no longer owns the progress state.
                try Task.checkCancellation()
                files.append(file)
                shareProgress = ShareProgress(completed: index + 1, total: total)
            }
            sharePayload = SharePayload(files: files)
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            let reason = error.localizedDescription
            Logger.files.error("Preparing \(document.title, privacy: .public) for sharing failed: \(reason, privacy: .public)")
            shareErrorMessage = error.userMessage
        }
    }

    private func cancelShare() {
        shareRequest = nil
        shareProgress = nil
    }

    /// Clears the preparation state, unless a newer request has taken it over meanwhile.
    private func finishShare(_ request: UUID) {
        guard shareRequest == request else { return }
        shareRequest = nil
        shareProgress = nil
    }
}

// MARK: - Supporting types

private extension ExamImagesScreen {
    struct OpenedPage: Identifiable {
        let index: Int
        var id: Int { index }
    }

    enum Layout {
        /// Pages wider than this are hard to read and overly tall; iPad and landscape center them.
        static let readableWidth: CGFloat = 700
        static let pageSpacing: CGFloat = 24
    }
}

private struct ShareProgress: Equatable {
    let completed: Int
    let total: Int

    var fraction: Double {
        total > 0 ? Double(completed) / Double(total) : 0
    }
}

private struct SharePayload: Identifiable {
    let id = UUID()
    let files: [URL]
}

// MARK: - Header

/// "BOZOK ÜNİVERSİTESİ › MÜHENDİSLİK MATEMATİĞİ · 3 sayfa", above the first page.
private struct ExamContextHeader: View {
    let subtitle: String
    let pageCount: Int

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: ExamKind.images.symbolName, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(subtitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(ExamKind.images.contentText(fileCount: pageCount))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Share preparation

/// A floating progress card while pages are saved for sharing, with a cancel button.
/// It appears only if preparing takes noticeable time, so cached pages share without a flash.
private struct SharePreparationBanner: View {
    let progress: ShareProgress
    let cancel: () -> Void

    @State private var isVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sayfalar hazırlanıyor")
                        .font(.subheadline.weight(.semibold))
                    Text("\(progress.completed) / \(progress.total) sayfa")
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Vazgeç", action: cancel)
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("exam.share.cancel")
            }
            ProgressView(value: progress.fraction)
                .animation(.easeOut, value: progress.fraction)
        }
        .padding(16)
        .frame(maxWidth: 420)
        .viewerSurface(in: .rect(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .contain)
        // Kept in the hierarchy while hidden so that its `.task` runs.
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        .task {
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            withAnimation(.snappy) {
                isVisible = true
            }
        }
    }
}

/// Presents the system share sheet from UIKit. Unlike `ShareLink`, it can open programmatically,
/// once the files exist on disk, and it reports whether the user completed the share.
private struct ActivitySheetPresenter: UIViewControllerRepresentable {
    @Binding var payload: SharePayload?
    let onCompletion: (_ completed: Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .clear
        controller.view.isUserInteractionEnabled = false
        return controller
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.presenter = self
        guard let payload, context.coordinator.presentedPayloadID != payload.id else { return }
        context.coordinator.present(payload, from: controller)
    }

    final class Coordinator {
        var presenter: ActivitySheetPresenter?
        private(set) var presentedPayloadID: SharePayload.ID?

        func present(_ payload: SharePayload, from controller: UIViewController) {
            presentedPayloadID = payload.id
            guard controller.viewIfLoaded?.window != nil, controller.presentedViewController == nil else {
                // Not on screen: drop the request after this update instead of leaving it pending.
                Task { [weak self] in self?.finish(completed: false) }
                return
            }

            let activityController = UIActivityViewController(activityItems: payload.files, applicationActivities: nil)
            if let popover = activityController.popoverPresentationController {
                // iPad: point at the trailing end of the navigation bar, where the share button is.
                let bounds = controller.view.bounds
                popover.sourceView = controller.view
                popover.sourceRect = CGRect(x: bounds.maxX - 44, y: bounds.minY, width: 44, height: 1)
                popover.permittedArrowDirections = .up
            }
            activityController.completionWithItemsHandler = { [weak self] _, completed, _, _ in
                self?.finish(completed: completed)
            }
            controller.present(activityController, animated: true)
        }

        private func finish(completed: Bool) {
            presentedPayloadID = nil
            presenter?.payload = nil
            presenter?.onCompletion(completed)
        }
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        ExamImagesView(path: ExamPreviewFixtures.imagesExamPath)
    }
    .environment(AppEnvironment.mock())
    .environment(Router())
}
#endif

import OSLog
import PDFKit
import SwiftUI

/// The viewer of a PDF exam: downloads the file, shows it with PDFKit and a floating page indicator,
/// shares it, and switches between files when the exam has several.
struct PDFExamView: View {
    let path: ArchivePath

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        PDFExamScreen(
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
private struct PDFExamScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(Router.self) private var router
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverEnabled
    @State private var viewModel: ExamDocumentViewModel
    @State private var loadAttempt = 0
    @State private var selectedFile = 0
    @State private var file: Loadable<LoadedPDF> = .loading
    @State private var fileAttempt = 0
    @State private var currentPage = 0
    @State private var isPageIndicatorVisible = true

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
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let document = viewModel.document, document.fileURLs.count > 1 {
                        filePicker(fileCount: document.fileURLs.count)
                    }
                    shareButton
                }
            }
            .task(id: loadAttempt) {
                await viewModel.loadIfNeeded()
            }
            .onAppear { environment.analytics.track(.screenView(name: "ExamPDF")) }
            .onChange(of: viewModel.document?.kind) { _, kind in
                redirectIfKindChanged(kind)
            }
            .task(id: fileRequest) { [request = fileRequest] in
                await loadFile(for: request)
            }
    }

    // MARK: - Routing

    /// The route's kind comes from a list summary or a stored recent exam. If the exam's files have
    /// changed kind since, replace this screen with the matching viewer.
    private func redirectIfKindChanged(_ kind: ExamKind?) {
        guard let kind, kind != .pdf, router.path.last == .exam(viewModel.path, .pdf) else { return }
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
        case let .loaded(document) where document.kind != .pdf:
            LoadingStateView()
        case let .loaded(document) where document.fileURLs.isEmpty:
            EmptyStateView(title: "Bu sınavda dosya yok", systemImage: "doc.richtext")
        case .loaded:
            fileContent
        }
    }

    @ViewBuilder
    private var fileContent: some View {
        switch file {
        case .loading:
            LoadingStateView(title: "Belge indiriliyor…")
        case let .failed(message):
            ErrorStateView(message: message) {
                fileAttempt += 1
            }
        case let .loaded(pdf):
            ZStack(alignment: .bottom) {
                PDFKitView(document: pdf.document, onPageChange: { currentPage = $0 })
                    .ignoresSafeArea(edges: .bottom)
                pageIndicator(pageCount: pdf.document.pageCount)
            }
            .task(id: currentPage) {
                await showPageIndicatorBriefly()
            }
        }
    }

    /// "3 / 12", floating above the pages; it fades out while the page does not change.
    @ViewBuilder
    private func pageIndicator(pageCount: Int) -> some View {
        if pageCount > 1, isPageIndicatorVisible || isVoiceOverEnabled {
            Text("\(currentPage + 1) / \(pageCount)")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .viewerSurface(in: Capsule())
                .padding(.bottom, 16)
                .transition(.opacity)
                .accessibilityLabel(Text("Sayfa \(currentPage + 1) / \(pageCount)"))
                .accessibilityIdentifier("exam.pdf.page")
        }
    }

    private func showPageIndicatorBriefly() async {
        withAnimation(.easeOut(duration: 0.2)) {
            isPageIndicatorVisible = true
        }
        do {
            try await Task.sleep(for: .seconds(2))
        } catch {
            return
        }
        withAnimation(.easeOut(duration: 0.4)) {
            isPageIndicatorVisible = false
        }
    }

    // MARK: - Toolbar

    private func filePicker(fileCount: Int) -> some View {
        Menu {
            Picker("Dosya", selection: $selectedFile) {
                ForEach(0..<fileCount, id: \.self) { index in
                    Text("Dosya \(index + 1)")
                        .tag(index)
                }
            }
        } label: {
            Label("Dosyalar", systemImage: "doc.on.doc")
        }
        .accessibilityIdentifier("exam.files")
    }

    @ViewBuilder
    private var shareButton: some View {
        if let pdf = file.value {
            ShareLink(item: pdf.fileURL) {
                Label("Paylaş", systemImage: "square.and.arrow.up")
            }
            // ShareLink reports no completion, so this records the intent to share.
            .simultaneousGesture(TapGesture().onEnded { viewModel.recordShare() })
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("exam.share")
        } else {
            // Holds the place of the share button while the file downloads.
            Button {} label: {
                Label("Paylaş", systemImage: "square.and.arrow.up")
            }
            .disabled(true)
            .accessibilityIdentifier("exam.share")
        }
    }

    // MARK: - File loading

    /// The file to show; `nil` until the document is loaded.
    private var fileRequest: FileRequest? {
        guard let document = viewModel.document,
              document.kind == .pdf,
              document.fileURLs.indices.contains(selectedFile) else { return nil }
        return FileRequest(url: document.fileURLs[selectedFile], index: selectedFile, attempt: fileAttempt)
    }

    /// Downloads the selected PDF (cached on disk) and opens it.
    private func loadFile(for request: FileRequest?) async {
        guard let request, let document = viewModel.document else { return }
        // `.task` runs again on every appearance; keep the file already on screen.
        if let shown = file.value, shown.remoteURL == request.url { return }

        file = .loading
        do {
            let localURL = try await environment.fileLoader.localFile(
                from: request.url,
                fileName: document.pdfFileName(at: request.index)
            )
            guard let pdfDocument = await PDFDocumentOpener.open(localURL) else {
                throw PDFExamError.unreadable
            }
            // Superseded by another file, or the screen went away.
            guard !Task.isCancelled else { return }
            currentPage = 0
            file = .loaded(LoadedPDF(remoteURL: request.url, fileURL: localURL, document: pdfDocument))
        } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            let reason = error.localizedDescription
            Logger.files.error(
                "PDF \(request.index + 1) of \(document.title, privacy: .public) failed to open: \(reason, privacy: .public)"
            )
            file = .failed(message: error.userMessage)
        }
    }
}

// MARK: - Supporting types

private struct FileRequest: Hashable {
    let url: URL
    let index: Int
    let attempt: Int
}

private struct LoadedPDF {
    /// The download URL the file came from.
    let remoteURL: URL
    /// The local copy, shown and shared.
    let fileURL: URL
    let document: PDFDocument
}

private enum PDFExamError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        switch self {
        case .unreadable:
            String(localized: "PDF belgesi açılamadı. Dosya bozuk olabilir.")
        }
    }
}

/// Opens PDFs off the main actor: parsing a large file can take a moment.
private nonisolated enum PDFDocumentOpener {
    @concurrent
    static func open(_ url: URL) async -> sending PDFDocument? {
        PDFDocument(url: url)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        PDFExamView(path: ExamPreviewFixtures.pdfExamPath)
    }
    .environment(AppEnvironment.mock())
    .environment(Router())
}
#endif

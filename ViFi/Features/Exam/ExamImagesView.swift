import SwiftUI
import UIKit

/// The viewer of an image exam: its pages as cards in a vertical scroll and a full-screen zoomable
/// pager on tap.
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

    init(viewModel: ExamDocumentViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        content
            // One background for every state, behind the bars too, so nothing flashes white.
            .background(Color(.systemGroupedBackground))
            .navigationTitle(viewModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: loadAttempt) {
                await viewModel.loadIfNeeded()
            }
            .onAppear { environment.analytics.track(.screenView(name: "ExamImages")) }
            .onChange(of: viewModel.document?.kind) { _, kind in
                redirectIfKindChanged(kind)
            }
            .fullScreenCover(item: $openedPage) { page in
                if let document = viewModel.document {
                    FullScreenPagerView(
                        document: document,
                        initialPage: page.index,
                        previews: pagePreviews
                    )
                    .environment(environment)
                }
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

#if DEBUG
#Preview {
    NavigationStack {
        ExamImagesView(path: ExamPreviewFixtures.imagesExamPath)
    }
    .environment(AppEnvironment.mock())
    .environment(Router())
}
#endif

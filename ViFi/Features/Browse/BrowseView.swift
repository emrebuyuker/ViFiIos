import SwiftUI

/// Lists the entries under `path` (faculties, departments, lessons or exams) below a breadcrumb trail.
struct BrowseView: View {
    let path: ArchivePath

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        BrowseScreen(path: path, repository: environment.repository)
    }
}

/// The screen itself. Split from `BrowseView` so the view model can be created from the
/// environment's repository and then owned by `@State` for the lifetime of the screen.
private struct BrowseScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(Router.self) private var router
    @State private var viewModel: BrowseViewModel
    @State private var hasTrackedLevel = false

    init(path: ArchivePath, repository: any ArchiveRepository) {
        _viewModel = State(initialValue: BrowseViewModel(path: path, repository: repository))
    }

    var body: some View {
        let items = viewModel.visibleItems

        List {
            Section {
                BreadcrumbBar(path: viewModel.path) { router.popTo($0) }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }

            if !items.isEmpty {
                Section {
                    ForEach(items) { item in
                        ArchiveNavigationRow(item: item)
                    }
                } header: {
                    ArchiveSectionHeader(title: listedLevel.listTitle, count: items.count)
                }
            }
        }
        .accessibilityIdentifier("browse.list")
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .scrollDismissesKeyboard(.immediately)
        .overlay { stateOverlay }
        .animation(.smooth, value: viewModel.state)
        .navigationTitle(viewModel.path.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $viewModel.searchText, prompt: listedLevel.searchPrompt)
        .refreshable { await viewModel.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Ana Sayfa", systemImage: "house") {
                    router.popToRoot()
                }
                .accessibilityIdentifier("toolbar.home")
            }
        }
        .task {
            trackScreen()
            await loadIfNeeded()
        }
        .task { await viewModel.refreshOnArchiveChanges() }
    }

    /// The level of the entries on this screen.
    private var listedLevel: ArchiveLevel {
        viewModel.path.childLevel ?? .exam
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch viewModel.state {
        case .loading:
            LoadingStateView()
        case let .failed(message):
            ErrorStateView(message: message) { reload() }
        case let .loaded(items) where items.isEmpty:
            EmptyStateView(
                title: listedLevel.emptyListTitle,
                systemImage: listedLevel.symbolName,
                message: "Yeni içerik eklendiğinde burada görünecek."
            )
        case .loaded where viewModel.visibleItems.isEmpty:
            SearchEmptyStateView(query: viewModel.searchQuery)
        case .loaded:
            EmptyView()
        }
    }

    // MARK: - Actions

    /// `.task` runs again whenever the screen reappears; only an unfinished load is restarted.
    private func loadIfNeeded() async {
        guard viewModel.state.isLoading else { return }
        await viewModel.load()
    }

    private func reload() {
        Task { await viewModel.load() }
    }

    /// The screen view is logged on every appearance; the level browse event once per screen.
    private func trackScreen() {
        environment.analytics.track(.screenView(name: "Browse"))
        guard !hasTrackedLevel else { return }
        hasTrackedLevel = true
        environment.analytics.track(.browse(level: listedLevel))
    }
}

/// "No results" state for a search query; shared by the home and browse lists.
struct SearchEmptyStateView: View {
    let query: String

    var body: some View {
        ContentUnavailableView.search(text: query)
            .accessibilityIdentifier("state.noResults")
    }
}

// MARK: - Level copy

extension ArchiveLevel {
    /// Prompt of the search field of a list of entries of this level.
    var searchPrompt: LocalizedStringKey {
        switch self {
        case .university: "Üniversite ara"
        case .faculty: "Fakültelerde ara"
        case .department: "Bölümlerde ara"
        case .lesson: "Derslerde ara"
        case .exam: "Sınavlarda ara"
        }
    }

    /// Empty-state title of a list of entries of this level.
    var emptyListTitle: LocalizedStringKey {
        switch self {
        case .university: "Henüz üniversite yok"
        case .faculty: "Bu üniversitede henüz fakülte yok"
        case .department: "Bu fakültede henüz bölüm yok"
        case .lesson: "Bu bölümde henüz ders yok"
        case .exam: "Bu derste henüz sınav yok"
        }
    }
}

#if DEBUG
#Preview("Sınavlar") {
    NavigationStack {
        BrowseView(
            path: ArchivePath(components: [
                "BOZOK ÜNİVERSİTESİ", "MÜHENDİSLİK MİMARLIK FAKÜLTESİ", "BİLGİSAYAR MÜHENDİSLİĞİ", "MÜHENDİSLİK MATEMATİĞİ",
            ])
        )
    }
    .environment(AppEnvironment.mock())
    .environment(Router())
}

#Preview("Boş ders") {
    NavigationStack {
        BrowseView(
            path: ArchivePath(components: [
                "KOCAELİ ÜNİVERSİTESİ", "MÜHENDİSLİK FAKÜLTESİ", "MATEMATİK BÖLÜMÜ", "TOPOLOJİ 2",
            ])
        )
    }
    .environment(AppEnvironment.mock())
    .environment(Router())
}
#endif

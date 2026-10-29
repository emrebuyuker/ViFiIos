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
    /// Whether the signed-in user is an admin (reveals the delete action on exams); resolved on appear.
    @State private var isAdmin = false
    /// The exam pending an admin deletion confirmation.
    @State private var examToDelete: ArchiveItem?
    @State private var deleteErrorMessage: String?
    /// The locked exam the user tapped, shown in the unlock sheet.
    @State private var examToUnlock: ArchiveItem?
    @State private var isShowingAddExam = false
    @State private var isShowingPaywall = false

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
                        ArchiveNavigationRow(
                            item: item,
                            isLocked: isLocked(item),
                            onLockedTap: { presentUnlockSheet(for: item) }
                        )
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                if canDeleteExams {
                                    Button(role: .destructive) {
                                        examToDelete = item
                                    } label: {
                                        Label("Sil", systemImage: "trash")
                                    }
                                    .accessibilityIdentifier("browse.delete.\(item.name)")
                                }
                            }
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
        .navigationTitle(viewModel.path.displayName ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $viewModel.searchText, prompt: listedLevel.searchPrompt)
        .refreshable { await viewModel.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                CoinBalanceBadge()
            }
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
        .task { isAdmin = await environment.auth.isCurrentUserAdmin() }
        .task(id: viewModel.searchQuery) { await trackSearch() }
        .alert("Sınav silinsin mi?", isPresented: deleteConfirmationBinding, presenting: examToDelete) { item in
            Button("Sil", role: .destructive) { performDelete(item) }
            Button("Vazgeç", role: .cancel) {}
        } message: { item in
            Text("\"\(item.name)\" arşivden kalıcı olarak silinir; bu işlem geri alınamaz.")
        }
        .alert("Silinemedi", isPresented: deleteErrorBinding) {
            Button("Tamam", role: .cancel) {}
        } message: {
            Text(deleteErrorMessage ?? "")
        }
        .sheet(item: $examToUnlock) { exam in
            ExamUnlockSheet(
                examName: exam.name,
                balance: environment.wallet.balance,
                unlock: { await environment.unlockExam(exam) },
                purchaseWithMoney: { await environment.purchaseExamUnlock(exam) },
                onUnlocked: { open(exam) },
                onEarnCoins: {
                    environment.analytics.track(.earnCoinsTapped)
                    examToUnlock = nil
                    isShowingAddExam = true
                },
                onGoPremium: {
                    examToUnlock = nil
                    isShowingPaywall = true
                }
            )
        }
        .sheet(isPresented: $isShowingAddExam) {
            AddExamView()
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isShowingPaywall) {
            PaywallView()
        }
    }

    /// The level of the entries on this screen.
    private var listedLevel: ArchiveLevel {
        viewModel.path.childLevel ?? .exam
    }

    /// The ids of this course's free (oldest) exams, computed from the full loaded list.
    private var freeExamIds: Set<String> {
        guard listedLevel == .exam, let exams = viewModel.state.value else { return [] }
        return ExamLock.freeExamIds(orderedExams: exams)
    }

    /// Whether `item` is a locked exam, by the archive's lock rule (`ExamLock.isLocked`, shared with the inbox).
    private func isLocked(_ item: ArchiveItem) -> Bool {
        ExamLock.isLocked(
            item,
            freeIds: freeExamIds,
            unlockedIds: environment.unlocks.unlockedIds,
            isSubscribed: environment.subscription.isSubscribed
        )
    }

    /// Shows the unlock sheet for a locked exam, recording whether the user can currently afford it.
    private func presentUnlockSheet(for item: ArchiveItem) {
        examToUnlock = item
        environment.trackUnlockSheetShown()
    }

    /// Opens an exam's viewer (used after a successful unlock).
    private func open(_ exam: ArchiveItem) {
        guard let kind = exam.exam?.kind else { return }
        router.openExam(at: exam.path, kind: kind)
    }

    /// Admins may delete the exams listed under a course.
    private var canDeleteExams: Bool {
        isAdmin && listedLevel == .exam
    }

    private var deleteConfirmationBinding: Binding<Bool> {
        Binding(get: { examToDelete != nil }, set: { if !$0 { examToDelete = nil } })
    }

    private var deleteErrorBinding: Binding<Bool> {
        Binding(get: { deleteErrorMessage != nil }, set: { if !$0 { deleteErrorMessage = nil } })
    }

    /// Deletes the exam from the archive (admin), removing it from the list on success.
    private func performDelete(_ item: ArchiveItem) {
        Task {
            do {
                try await environment.moderationService.deleteExam(at: item.path)
                viewModel.remove(item)
            } catch {
                deleteErrorMessage = error.userMessage
            }
        }
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

    /// Reports a search once the user pauses typing, with whether it returned any results. Debounced by the
    /// task's own cancellation: a new keystroke restarts the task and cancels this pending report.
    private func trackSearch() async {
        guard !viewModel.searchQuery.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(700))
        guard !Task.isCancelled else { return }
        environment.analytics.track(.searchUsed(level: listedLevel, zeroResults: viewModel.visibleItems.isEmpty))
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

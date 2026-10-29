import SwiftUI
import UIKit

/// The root screen: hero header, recently opened exams and the university list.
struct HomeView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        HomeScreen(repository: environment.repository)
    }
}

/// The screen itself. Split from `HomeView` so the view model can be created from the
/// environment's repository and then owned by `@State` for the lifetime of the screen.
private struct HomeScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(Router.self) private var router
    @State private var viewModel: BrowseViewModel
    @State private var isShowingAbout = false
    @State private var isShowingAccount = false
    @State private var isShowingAddExam = false
    @State private var isShowingPriming = false

    init(repository: any ArchiveRepository) {
        _viewModel = State(initialValue: BrowseViewModel(path: .root, repository: repository))
    }

    var body: some View {
        let recentExams = environment.recents.exams

        List {
            // While searching, only the matching universities are relevant.
            if !viewModel.isFiltering {
                HomeHeroHeader()

                addExamSection

                if !recentExams.isEmpty {
                    RecentExamsSection(
                        exams: recentExams,
                        onOpen: { openRecentExam($0) },
                        onRemove: { environment.recents.remove($0) },
                        onClear: { environment.recents.clear() }
                    )
                }
            }

            universitiesSection
        }
        .accessibilityIdentifier("home.list")
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.immediately)
        .animation(.smooth, value: viewModel.state)
        .animation(.smooth, value: viewModel.isFiltering)
        .animation(.smooth, value: recentExams)
        .navigationTitle(Text(verbatim: "ViFi"))
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $viewModel.searchText, prompt: ArchiveLevel.university.searchPrompt)
        .refreshable { await viewModel.refresh() }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                CoinBalanceBadge()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    environment.notificationRouter.openInbox()
                } label: {
                    Label("Bildirimler", systemImage: environment.inbox.unreadCount > 0 ? "bell.badge.fill" : "bell")
                }
                .accessibilityIdentifier("toolbar.inbox")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Hakkında", systemImage: "info.circle") {
                    showAbout()
                }
                .accessibilityIdentifier("toolbar.about")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Hesap", systemImage: "person.crop.circle") {
                    showAccount()
                }
                .accessibilityIdentifier("toolbar.account")
            }
        }
        .sheet(isPresented: $isShowingAbout, onDismiss: trackScreen) {
            AboutView()
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isShowingAccount, onDismiss: trackScreen) {
            AccountView()
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isShowingAddExam, onDismiss: trackScreen) {
            AddExamView()
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isShowingPriming, onDismiss: trackScreen) {
            NotificationPrimingView(
                onEnable: {
                    isShowingPriming = false
                    Task { await environment.notifications.requestAuthorization() }
                },
                onDismiss: { isShowingPriming = false }
            )
        }
        .task {
            trackScreen()
            await loadIfNeeded()
        }
        // Offer notifications once the user has a profile (this screen) and the onboarding tour is gone.
        .task { await offerNotificationsIfNeeded() }
        .onChange(of: environment.onboarding.isPresenting) { _, isPresenting in
            if !isPresenting {
                Task { await offerNotificationsIfNeeded() }
                Task { await showPendingNotification() }
            }
        }
        // A tapped push opens the inbox from here: this screen exists only once every gate (required update,
        // sign-in, profile) is passed, so a tap that launched the app waits for it. Keyed on the request, so a newer
        // tap replaces a waiting one.
        .task(id: environment.notificationRouter.pending) { await showPendingNotification() }
        // The inbox is presented from `RootView`; time on Home is credited again once it closes.
        .onChange(of: environment.notificationRouter.isInboxPresented) { _, isPresented in
            if !isPresented {
                trackScreen()
            }
        }
        .task { await viewModel.refreshOnArchiveChanges() }
    }

    // MARK: - Add exam

    /// A call to action inviting the signed-in user to contribute an exam.
    private var addExamSection: some View {
        Section {
            Button {
                showAddExam()
            } label: {
                HStack(spacing: 14) {
                    IconBadge(systemName: "plus.rectangle.on.rectangle", tint: .accentColor, size: 40)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Sınav Ekle")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("Arşive sınav ekle, onaylanınca coin kazan.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 4)
            }
            .accessibilityIdentifier("home.addExam")
        }
    }

    // MARK: - Universities

    private var universitiesSection: some View {
        Section {
            universitiesContent
        } header: {
            ArchiveSectionHeader(
                title: ArchiveLevel.university.listTitle,
                count: viewModel.state.value == nil ? nil : viewModel.visibleItems.count
            )
        }
        .headerProminence(.increased)
    }

    /// The rows, or a placeholder row for the loading, error and empty states — so the hero and the
    /// recents stay usable while the list loads or fails.
    @ViewBuilder
    private var universitiesContent: some View {
        switch viewModel.state {
        case .loading:
            LoadingStateView()
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
        case let .failed(message):
            ErrorStateView(message: message) { reload() }
                .listRowBackground(Color.clear)
        case let .loaded(universities) where universities.isEmpty:
            EmptyStateView(
                title: ArchiveLevel.university.emptyListTitle,
                systemImage: ArchiveLevel.university.symbolName,
                message: "Yeni içerik eklendiğinde burada görünecek."
            )
            .listRowBackground(Color.clear)
        case .loaded where viewModel.visibleItems.isEmpty:
            SearchEmptyStateView(query: viewModel.searchQuery)
                .listRowBackground(Color.clear)
        case .loaded:
            ForEach(viewModel.visibleItems) { university in
                ArchiveNavigationRow(item: university)
            }
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

    private func openRecentExam(_ exam: RecentExam) {
        environment.analytics.track(.recentExamOpened)
        router.openExam(at: exam.path, kind: exam.kind)
    }

    private func showAbout() {
        environment.analytics.track(.screenView(name: "About"))
        isShowingAbout = true
    }

    private func showAccount() {
        environment.analytics.track(.screenView(name: "Account"))
        isShowingAccount = true
    }

    private func showAddExam() {
        // The AddExam screen view is logged by AddExamView.onAppear (reached from here and from Browse),
        // so it is not tracked again here.
        isShowingAddExam = true
    }

    /// Shows the notification pre-permission screen once per device: after the profile is in place (this
    /// screen), after the onboarding tour, and only while the OS permission has not been decided yet.
    private func offerNotificationsIfNeeded() async {
        guard !environment.onboarding.isPresenting,
              !isShowingPriming,
              !NotificationPrimingDefaults.hasOffered(),
              await environment.notifications.permission() == .notDetermined else { return }
        NotificationPrimingDefaults.markOffered()
        isShowingPriming = true
    }

    /// Opens the inbox for a tapped push, once nothing else is in the way. The onboarding tour is left to finish (it
    /// calls this again). Sheets with nothing to lose (About, the notification priming) make way; any other modal —
    /// adding an exam, the account screen and its forms, a paywall or unlock sheet over an exam list — may hold the
    /// user's work or a purchase, so it is never closed: the inbox opens as soon as it is. (SwiftUI cannot present
    /// the inbox over another sheet; trying would leave it marked open but invisible, and the bell dead.)
    private func showPendingNotification() async {
        let notificationRouter = environment.notificationRouter
        guard notificationRouter.pending != nil, !environment.onboarding.isPresenting else { return }
        if notificationRouter.isInboxPresented {
            // Already open: just move the highlight to the tapped entry.
            notificationRouter.deliverPending()
            return
        }
        isShowingAbout = false
        isShowingPriming = false
        while ModalPresentation.isShowing {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, notificationRouter.pending != nil else { return }
        }
        notificationRouter.deliverPending()
    }

    /// Logged on every appearance (and after the About and Account sheets close) so time is credited to Home.
    private func trackScreen() {
        environment.analytics.track(.screenView(name: "Home"))
    }
}

/// Whether the app shows a modal (sheet, cover or alert) over its main screen, from any view. SwiftUI offers no
/// app-wide view of that, so it is read from the key window's presentation chain.
private enum ModalPresentation {
    static var isShowing: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { $0.isKeyWindow && $0.rootViewController?.presentedViewController != nil }
    }
}

/// Logo and tagline above the lists; drawn without a row background.
private struct HomeHeroHeader: View {
    @ScaledMetric(relativeTo: .title2) private var logoSize: CGFloat = 56

    var body: some View {
        Section {
            HStack(spacing: 14) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: clampedLogoSize, height: clampedLogoSize)
                    .clipShape(.rect(cornerRadius: clampedLogoSize * 0.25, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: clampedLogoSize * 0.25, style: .continuous)
                            .strokeBorder(Color(.separator), lineWidth: 0.5)
                    }
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Sınav Arşivi")
                        .font(.title2.bold())
                    Text("Üniversitelerin geçmiş sınavlarına hızlıca ulaş.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            // Aligned with the large title and the edges of the grouped rows.
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        }
    }

    private var clampedLogoSize: CGFloat {
        min(logoSize, 88)
    }
}

#if DEBUG
/// The mock environment with a few exams already opened, to preview the recents shelf.
private func previewEnvironmentWithRecents() -> AppEnvironment {
    let environment = AppEnvironment.mock()
    let lesson = ArchivePath(components: [
        "BOZOK ÜNİVERSİTESİ", "MÜHENDİSLİK MİMARLIK FAKÜLTESİ", "BİLGİSAYAR MÜHENDİSLİĞİ", "MÜHENDİSLİK MATEMATİĞİ",
    ])
    environment.recents.record(path: lesson.appending("2018 VİZE"), kind: .pdf, at: .now.addingTimeInterval(-86_400))
    environment.recents.record(path: lesson.appending("2019 FİNAL"), kind: .images, at: .now.addingTimeInterval(-600))
    return environment
}

#Preview("Ana Sayfa") {
    NavigationStack {
        HomeView()
    }
    .environment(AppEnvironment.mock())
    .environment(Router())
}

#Preview("Son görüntülenenlerle") {
    NavigationStack {
        HomeView()
    }
    .environment(previewEnvironmentWithRecents())
    .environment(Router())
}
#endif

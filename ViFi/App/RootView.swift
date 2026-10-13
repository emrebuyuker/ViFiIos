import os
import SwiftUI

/// Gates the app behind sign-in, hosts the navigation stack and app-wide concerns (update prompt).
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(Router.self) private var router
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var updateStatus: AppUpdateStatus = .upToDate
    /// The optional version dismissed with "Daha Sonra" this launch; shown again next launch.
    @State private var dismissedOptionalVersion: String?
    /// The optional version the user chose to skip for good (persisted across launches).
    @State private var skippedOptionalVersion: String? = UpdatePromptDefaults.skippedVersion
    /// The required version a prompt-shown event was already logged for, so it is counted once.
    @State private var promptedRequiredVersion: String?

    var body: some View {
        // The required-update gate replaces the whole UI rather than presenting a modal: it cannot be
        // dismissed, nothing behind it stays interactive, and it never races the optional alert's presentation.
        ZStack {
            if case let .required(update) = updateStatus {
                ForceUpdateView(update: update)
            } else {
                content
            }
        }
        // A privacy cover over the whole app while it is not active, so exam content never shows in the app
        // switcher's snapshot. No animation: the snapshot is taken the instant the app becomes inactive, so the
        // cover must be in place immediately.
        .overlay {
            if scenePhase != .active {
                AppSwitcherCover()
            }
        }
        .task { await environment.session.observeUserChanges() }
        .task { await observeUpdateStatus() }
        .onChange(of: environment.session.state) { _, state in
            // The next user starts on the home screen, not deep in the previous user's stack, with a clean
            // profile read and without the previous user's recently-viewed list. Downloaded files are kept
            // (re-login needs no re-download); account deletion wipes them separately, in `AccountViewModel`.
            if state == .signedOut {
                router.popToRoot()
                environment.profile.reset()
                environment.wallet.reset()
                environment.unlocks.reset()
                environment.recents.clear()
                environment.announcements.reset()
                // Clear the analytics identity so the next user is not attributed to the previous one.
                environment.analytics.setUser(nil)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Trim the on-disk file cache back within budget while the app is idle.
            if phase == .background {
                Task { await environment.fileLoader.pruneDiskCache() }
            }
        }
        .onOpenURL { url in
            // The reCAPTCHA fallback of phone sign-in returns through the app's URL scheme.
            if !environment.auth.canHandle(url) {
                Logger.app.notice("Ignoring unhandled URL \(url, privacy: .private)")
            }
        }
        .alert(
            "Yeni sürüm mevcut",
            isPresented: optionalPromptBinding,
            presenting: pendingOptionalUpdate
        ) { update in
            Button("Güncelle") {
                environment.analytics.track(.updateAction(action: "update"))
                openURL(update.storeURL)
            }
            Button("Bu sürümü atla") {
                environment.analytics.track(.updateAction(action: "skip"))
                skipOptional(update)
            }
            Button("Daha Sonra", role: .cancel) {
                environment.analytics.track(.updateAction(action: "later"))
            }
        } message: { update in
            Text(update.message ?? "ViFi \(update.version) App Store'da. En iyi deneyim için uygulamayı güncelle.")
        }
        // The optional prompt is counted when it actually appears (a new, non-skipped optional version).
        .onChange(of: pendingOptionalUpdate?.version) { _, version in
            if version != nil {
                environment.analytics.track(.updatePromptShown(isRequired: false))
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch environment.session.state {
        case .unknown:
            SessionLoadingView()
        case .signedOut:
            LoginView()
        case let .signedIn(user):
            // The archive is gated a second time behind a completed profile.
            ProfileGate(user: user) { archive }
        }
    }

    private var archive: some View {
        @Bindable var router = router
        @Bindable var onboarding = environment.onboarding
        return NavigationStack(path: $router.path) {
            HomeView()
                .navigationDestination(for: Route.self, destination: destination)
        }
        // Warm the offline cache once the signed-in user reaches the archive; cancelled on sign-out.
        .task { await environment.prefetcher.prefetchIfNeeded() }
        // First-launch tour, over the archive so the home screen and its prefetch load underneath. Skipping
        // or finishing marks it seen (per device), so it shows only once; it is replayable from About.
        .fullScreenCover(isPresented: $onboarding.isPresenting) {
            OnboardingView(onFinish: { environment.onboarding.markSeen() })
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case let .browse(path):
            BrowseView(path: path)
        case let .exam(path, .images):
            ExamImagesView(path: path)
        case let .exam(path, .pdf):
            PDFExamView(path: path)
        }
    }

    // MARK: - App update

    /// Keeps the gate in sync with the live policy for the app's lifetime; the stream re-emits whenever
    /// the remote policy changes, so a newly required version gates even a running session.
    private func observeUpdateStatus() async {
        for await status in environment.updateChecker.statusChanges() {
            updateStatus = status
            // The required gate always shows; count it once per version. (The optional prompt is counted when
            // it is actually presented — see the `pendingOptionalUpdate` change handler.)
            if case let .required(update) = status, update.version != promptedRequiredVersion {
                promptedRequiredVersion = update.version
                environment.analytics.track(.updatePromptShown(isRequired: true))
            }
        }
    }

    /// The optional update to prompt for, or `nil` when there is none, it was dismissed, or it was skipped.
    private var pendingOptionalUpdate: AppUpdate? {
        guard case let .optional(update) = updateStatus,
              update.version != dismissedOptionalVersion,
              update.version != skippedOptionalVersion else {
            return nil
        }
        return update
    }

    private var optionalPromptBinding: Binding<Bool> {
        Binding(
            get: { pendingOptionalUpdate != nil },
            // Any dismissal (Update, skip, Later, tap-away) suppresses this version until relaunch; keying
            // on the version means a later, different optional version prompts again.
            set: { if !$0 { dismissedOptionalVersion = pendingOptionalUpdate?.version } }
        )
    }

    private func skipOptional(_ update: AppUpdate) {
        skippedOptionalVersion = update.version
        UpdatePromptDefaults.skippedVersion = update.version
    }
}

/// Remembers the optional-update version the user chose to skip, so it is not shown again.
private enum UpdatePromptDefaults {
    private static let key = "skippedUpdateVersion"

    static var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

/// Second gate behind sign-in: the archive is shown only once the signed-in user has completed their
/// profile. Loads the profile when the user appears or changes, offering a retry if the read fails.
private struct ProfileGate<Content: View>: View {
    let user: AuthUser
    @ViewBuilder let content: () -> Content

    @Environment(AppEnvironment.self) private var environment
    @State private var isAdmin = false

    init(user: AuthUser, @ViewBuilder content: @escaping () -> Content) {
        self.user = user
        self.content = content
    }

    var body: some View {
        gatedContent
            .task(id: user.id) { await environment.profile.load(uid: user.id) }
            // Follow the user's coin balance for as long as they are signed in, so every screen shows it.
            .task(id: user.id) { await environment.wallet.observe(uid: user.id) }
            // Load the user's unlocked exams, for the archive's lock state.
            .task(id: user.id) { await environment.unlocks.load(uid: user.id) }
            // Keep the notification inbox (public announcements) in step while signed in.
            .task(id: user.id) { await environment.announcements.observe() }
            // Identify the user for analytics: id + admin now, enriched with profile segments once loaded.
            .task(id: user.id) {
                isAdmin = await environment.auth.isCurrentUserAdmin()
                identifyUser()
            }
            .onChange(of: environment.profile.state) { _, _ in identifyUser() }
    }

    /// Sets the analytics identity from the current profile (when present), admin status and user id.
    private func identifyUser() {
        environment.analytics.setUser(
            AnalyticsUser(id: user.id, profile: environment.profile.profile, isAdmin: isAdmin)
        )
    }

    @ViewBuilder
    private var gatedContent: some View {
        switch environment.profile.state {
        case .loading:
            SessionLoadingView()
        case .absent:
            ProfileCompletionView(user: user)
        case .present:
            content()
        case let .failed(message):
            ErrorStateView(message: message) {
                Task { await environment.profile.load(uid: user.id) }
            }
        }
    }
}

/// An opaque branded cover shown over the whole app while it is inactive or backgrounded, so no screen
/// (exam content included) appears in the multitasking snapshot.
private struct AppSwitcherCover: View {
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

/// Shown for the moment it takes to restore the stored session at launch.
private struct SessionLoadingView: View {
    @ScaledMetric(relativeTo: .largeTitle) private var logoSize: CGFloat = 84

    var body: some View {
        VStack(spacing: 24) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: min(logoSize, 120), height: min(logoSize, 120))
                .clipShape(.rect(cornerRadius: min(logoSize, 120) * 0.225, style: .continuous))
                .accessibilityHidden(true)
            ProgressView()
                .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Yükleniyor…")
        .accessibilityIdentifier("session.loading")
    }
}

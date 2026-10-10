import os
import SwiftUI

/// Gates the app behind sign-in, hosts the navigation stack and app-wide concerns (update prompt).
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(Router.self) private var router
    @Environment(\.openURL) private var openURL
    @State private var updateStatus: AppUpdateStatus = .upToDate
    /// The optional version dismissed with "Daha Sonra" this launch; shown again next launch.
    @State private var dismissedOptionalVersion: String?
    /// The optional version the user chose to skip for good (persisted across launches).
    @State private var skippedOptionalVersion: String? = UpdatePromptDefaults.skippedVersion

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
        .task { await environment.session.observeUserChanges() }
        .task { await observeUpdateStatus() }
        .onChange(of: environment.session.state) { _, state in
            // The next user starts on the home screen, not deep in the previous user's stack.
            if state == .signedOut {
                router.popToRoot()
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
            Button("Güncelle") { openURL(update.storeURL) }
            Button("Bu sürümü atla") { skipOptional(update) }
            Button("Daha Sonra", role: .cancel) {}
        } message: { update in
            Text(update.message ?? "ViFi \(update.version) App Store'da. En iyi deneyim için uygulamayı güncelle.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch environment.session.state {
        case .unknown:
            SessionLoadingView()
        case .signedOut:
            LoginView()
        case .signedIn:
            archive
        }
    }

    private var archive: some View {
        @Bindable var router = router
        return NavigationStack(path: $router.path) {
            HomeView()
                .navigationDestination(for: Route.self, destination: destination)
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

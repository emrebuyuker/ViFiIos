import os
import SwiftUI

/// Gates the app behind sign-in, hosts the navigation stack and app-wide concerns (update prompt).
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(Router.self) private var router
    @Environment(\.openURL) private var openURL
    @State private var availableUpdate: AppUpdate?

    var body: some View {
        content
            .task { await environment.session.observeUserChanges() }
            .task { await checkForUpdate() }
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
                isPresented: Binding(
                    get: { availableUpdate != nil },
                    set: { if !$0 { availableUpdate = nil } }
                ),
                presenting: availableUpdate
            ) { update in
                Button("Güncelle") { openURL(update.storeURL) }
                Button("Daha Sonra", role: .cancel) {}
            } message: { update in
                Text("ViFi \(update.version) App Store'da. En iyi deneyim için uygulamayı güncelle.")
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

    private func checkForUpdate() async {
        availableUpdate = await environment.updateChecker.availableUpdate()
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

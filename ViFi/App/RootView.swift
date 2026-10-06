import SwiftUI

/// Hosts the navigation stack and app-wide concerns (update prompt).
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(Router.self) private var router
    @Environment(\.openURL) private var openURL
    @State private var availableUpdate: AppUpdate?

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
            HomeView()
                .navigationDestination(for: Route.self, destination: destination)
        }
        .task { await checkForUpdate() }
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

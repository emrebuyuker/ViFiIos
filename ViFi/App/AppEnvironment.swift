import Foundation
import Observation
import FirebaseCore

/// The app's services, injected into SwiftUI with `.environment(_:)`.
@Observable
final class AppEnvironment {
    @ObservationIgnored let repository: any ArchiveRepository
    @ObservationIgnored let fileLoader: any RemoteFileLoading
    @ObservationIgnored let updateChecker: any AppUpdateChecking
    @ObservationIgnored let analytics: any AnalyticsTracking
    let recents: RecentExamsStore

    init(
        repository: any ArchiveRepository,
        fileLoader: any RemoteFileLoading,
        updateChecker: any AppUpdateChecking,
        analytics: any AnalyticsTracking,
        recents: RecentExamsStore
    ) {
        self.repository = repository
        self.fileLoader = fileLoader
        self.updateChecker = updateChecker
        self.analytics = analytics
        self.recents = recents
    }

    /// Production services backed by Firebase and the App Store.
    static func live() -> AppEnvironment {
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        return AppEnvironment(
            repository: FirebaseArchiveRepository(),
            fileLoader: RemoteFileLoader(),
            updateChecker: AppStoreUpdateChecker(),
            analytics: FirebaseAnalyticsTracker(),
            recents: RecentExamsStore()
        )
    }

    /// `live()`, or bundled sample data when launched with `-ViFiMockData` (UI tests, demos).
    static func makeDefault(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppEnvironment {
        #if DEBUG
        if arguments.contains(LaunchArgument.mockData) {
            return mock()
        }
        #endif
        return live()
    }
}

enum LaunchArgument {
    /// Runs the app on bundled sample data without touching Firebase or the network.
    static let mockData = "-ViFiMockData"
}

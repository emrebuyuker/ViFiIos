import FirebaseAppCheck
import FirebaseAuth
import FirebaseCore
import Foundation
import Observation

/// The app's services, injected into SwiftUI with `.environment(_:)`.
@Observable
final class AppEnvironment {
    @ObservationIgnored let repository: any ArchiveRepository
    @ObservationIgnored let fileLoader: any RemoteFileLoading
    @ObservationIgnored let updateChecker: any AppUpdateChecking
    @ObservationIgnored let analytics: any AnalyticsTracking
    @ObservationIgnored let auth: any AuthServicing
    let recents: RecentExamsStore
    let session: SessionStore

    init(
        repository: any ArchiveRepository,
        fileLoader: any RemoteFileLoading,
        updateChecker: any AppUpdateChecking,
        analytics: any AnalyticsTracking,
        auth: any AuthServicing,
        recents: RecentExamsStore
    ) {
        self.repository = repository
        self.fileLoader = fileLoader
        self.updateChecker = updateChecker
        self.analytics = analytics
        self.auth = auth
        self.recents = recents
        session = SessionStore(auth: auth)
    }

    /// Production services backed by Firebase and the App Store.
    ///
    /// Call only once `UIApplication` exists (see `AppDelegate.environment`): Firebase Auth, created by
    /// `FirebaseApp.configure()`, needs it to set up phone sign-in.
    static func live() -> AppEnvironment {
        if FirebaseApp.app() == nil {
            // App Check must be set up before Firebase is configured.
            AppCheck.setAppCheckProviderFactory(ViFiAppCheckProviderFactory())
            FirebaseApp.configure()
        }
        let firebaseAuth = Auth.auth()
        let auth = FirebaseAuthService(auth: firebaseAuth)
        let authorizer = FirebaseRequestAuthorizer(
            auth: firebaseAuth,
            appCheck: AppCheck.appCheck(),
            storageBucket: FirebaseApp.app()?.options.storageBucket
        )
        return AppEnvironment(
            repository: FirebaseArchiveRepository(auth: auth),
            fileLoader: RemoteFileLoader(authorizer: authorizer),
            updateChecker: AppStoreUpdateChecker(),
            analytics: FirebaseAnalyticsTracker(),
            auth: auth,
            recents: RecentExamsStore()
        )
    }

    /// `live()`, or bundled sample data when launched with `-ViFiMockData` (UI tests, demos).
    static func makeDefault(arguments: [String] = ProcessInfo.processInfo.arguments) -> AppEnvironment {
        #if DEBUG
        if usesMockData(arguments: arguments) {
            return mock(arguments: arguments)
        }
        #endif
        return live()
    }

    /// Whether the app runs on bundled sample data, without Firebase (`-ViFiMockData`, Debug builds only).
    static func usesMockData(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        #if DEBUG
        arguments.contains(LaunchArgument.mockData)
        #else
        false
        #endif
    }
}

enum LaunchArgument {
    /// Runs the app on bundled sample data without touching Firebase or the network.
    static let mockData = "-ViFiMockData"

    #if DEBUG
    /// With `-ViFiMockData`: starts signed out, to exercise the login screen.
    static let signedOut = "-ViFiSignedOut"
    /// Disables phone auth app verification (APNs / reCAPTCHA); works only with the console's test numbers.
    static let phoneAuthTesting = "-ViFiPhoneAuthTesting"
    #endif
}

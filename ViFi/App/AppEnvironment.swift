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
    @ObservationIgnored let profileService: any ProfileServicing
    /// Uploads user-contributed exams for moderation (Cloud Firestore + Cloud Storage).
    @ObservationIgnored let submissionService: any ExamSubmissionServicing
    /// Remote reward values (the coin amount shown in the add-exam flow).
    @ObservationIgnored let rewardsConfig: any RewardsConfigReading
    /// Reads the signed-in user's coin balance (shown across the app).
    @ObservationIgnored let walletReader: any WalletReading
    /// Admin-only moderation of user submissions (approve → publish + credit, or reject).
    @ObservationIgnored let moderationService: any ModerationServicing
    /// Unlocks a locked exam by spending coins (via the server-side Cloud Function).
    @ObservationIgnored let unlockService: any ExamUnlockServicing
    /// Unlocks a single exam paid for with money (StoreKit consumable + the server-side Cloud Function).
    @ObservationIgnored let examPurchaseService: any ExamPurchaseServicing
    /// The bundled lists backing the profile pickers (free text is always allowed on top).
    @ObservationIgnored let catalog: UniversityCatalog
    /// The Storage bucket, for building canonical file URLs (e.g. previewing a submission's pending files).
    @ObservationIgnored let storageBucket: String
    /// Warms the archive's offline cache after sign-in (see `ArchivePrefetcher`).
    @ObservationIgnored let prefetcher: ArchivePrefetcher
    let recents: RecentExamsStore
    let session: SessionStore
    let profile: ProfileStore
    /// The signed-in user's coin balance, kept live and shown across the app.
    let wallet: CoinWalletStore
    /// The signed-in user's unlocked exams, for the archive's lock state.
    let unlocks: ExamUnlocksStore
    /// The device's premium (subscription) state; when active, the whole archive is unlocked.
    let subscription: SubscriptionStore
    /// Whether the first-launch onboarding tour should be shown (a per-device flag).
    let onboarding: OnboardingStore
    /// Requests and reports the OS notification permission.
    @ObservationIgnored let notifications: any NotificationServicing
    /// Reports failed sign-in attempts for support diagnostics (why a number could not sign in).
    @ObservationIgnored let loginDiagnostics: any LoginDiagnosticsReporting
    /// The in-app notification inbox: public announcements + the user's own notifications, with the unread count.
    let inbox: InboxStore
    /// Opens the inbox from a tapped push (once the app is past its gates) and from the bell.
    let notificationRouter: NotificationRouter
    /// Reports opened / acted-on notifications for the admin history's statistics (fire-and-forget, once per user).
    let notificationEvents: NotificationEventTracker
    /// Registers this device's push token under the signed-in user (targeted and personal notifications).
    let deviceRegistration: DeviceRegistrationStore
    /// Admin-only targeted notification sending ("Bildirim Gönder"; NOTIFICATIONS.md).
    @ObservationIgnored let notificationAdmin: any NotificationAdminServicing
    /// The signed-in user's campaign-notification consent (Apple 4.5.4), live from Firestore.
    let notificationSettings: NotificationSettingsStore
    /// Decides when the notification permission flow is offered and hands it to the screen that presents it.
    let notificationPrompts: NotificationPromptCoordinator
    /// The admin's map screen for choosing a campaign's location (Google Maps; a stub in mock mode).
    @ObservationIgnored let locationPicker: any LocationPicking

    init(
        repository: any ArchiveRepository,
        fileLoader: any RemoteFileLoading,
        updateChecker: any AppUpdateChecking,
        analytics: any AnalyticsTracking,
        auth: any AuthServicing,
        profileService: any ProfileServicing,
        submissionService: any ExamSubmissionServicing,
        rewardsConfig: any RewardsConfigReading,
        walletReader: any WalletReading,
        moderationService: any ModerationServicing,
        unlockService: any ExamUnlockServicing,
        unlocksReader: any UnlocksReading,
        examPurchaseService: any ExamPurchaseServicing,
        subscriptionService: any SubscriptionServicing,
        catalog: UniversityCatalog,
        storageBucket: String = "",
        recents: RecentExamsStore,
        prefetcherDefaults: UserDefaults = .standard,
        onboardingDefaults: UserDefaults = .standard,
        notifications: any NotificationServicing,
        inboxReader: any InboxReading,
        inboxDefaults: UserDefaults = .standard,
        notificationAdmin: any NotificationAdminServicing,
        deviceRegistrar: any DeviceRegistering,
        notificationSettingsService: any NotificationSettingsServicing,
        notificationPromptDefaults: UserDefaults = .standard,
        loginDiagnostics: any LoginDiagnosticsReporting = NoopLoginDiagnosticsReporter(),
        locationPicker: any LocationPicking = GoogleLocationPicker(),
        notificationEventReporter: any NotificationEventReporting = NoopNotificationEventReporter(),
        notificationEventDefaults: UserDefaults = .standard
    ) {
        self.repository = repository
        self.fileLoader = fileLoader
        self.updateChecker = updateChecker
        self.analytics = analytics
        self.auth = auth
        self.profileService = profileService
        self.submissionService = submissionService
        self.rewardsConfig = rewardsConfig
        self.walletReader = walletReader
        self.moderationService = moderationService
        self.unlockService = unlockService
        self.examPurchaseService = examPurchaseService
        self.catalog = catalog
        self.storageBucket = storageBucket
        self.recents = recents
        prefetcher = ArchivePrefetcher(repository: repository, defaults: prefetcherDefaults)
        session = SessionStore(auth: auth)
        profile = ProfileStore(service: profileService)
        wallet = CoinWalletStore(reader: walletReader)
        unlocks = ExamUnlocksStore(reader: unlocksReader)
        subscription = SubscriptionStore(service: subscriptionService)
        onboarding = OnboardingStore(defaults: onboardingDefaults)
        self.notifications = notifications
        inbox = InboxStore(reader: inboxReader, defaults: inboxDefaults)
        notificationRouter = NotificationRouter()
        notificationEvents = NotificationEventTracker(reporter: notificationEventReporter, defaults: notificationEventDefaults)
        deviceRegistration = DeviceRegistrationStore(registrar: deviceRegistrar)
        self.notificationAdmin = notificationAdmin
        let settings = NotificationSettingsStore(service: notificationSettingsService)
        notificationSettings = settings
        notificationPrompts = NotificationPromptCoordinator(
            notifications: notifications,
            settings: settings,
            history: NotificationPromptHistory(defaults: notificationPromptDefaults),
            analytics: analytics
        )
        self.loginDiagnostics = loginDiagnostics
        self.locationPicker = locationPicker
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
        let bucket = FirebaseApp.app()?.options.storageBucket
        let authorizer = FirebaseRequestAuthorizer(
            auth: firebaseAuth,
            appCheck: AppCheck.appCheck(),
            storageBucket: bucket
        )
        // Cutover: the archive is read from Cloud Firestore (named `vifi` database). The Realtime Database
        // `FirebaseArchiveRepository(auth:)` is kept available for rollback.
        let repository = FirestoreArchiveRepository(bucket: bucket ?? "")
        let rewardsConfig = FirebaseRewardsConfigReader()
        return AppEnvironment(
            repository: repository,
            fileLoader: RemoteFileLoader(authorizer: authorizer),
            updateChecker: RemoteAppUpdateChecker(config: FirebaseRemoteConfigReader()),
            analytics: FirebaseAnalyticsTracker(),
            auth: auth,
            profileService: FirebaseProfileService(auth: auth),
            submissionService: FirebaseExamSubmissionService(auth: auth),
            rewardsConfig: rewardsConfig,
            walletReader: FirebaseWalletReader(),
            moderationService: FirebaseModerationService(repository: repository, rewards: rewardsConfig),
            unlockService: FirebaseExamUnlockService(),
            unlocksReader: FirebaseUnlocksReader(),
            examPurchaseService: StoreKitExamPurchaseService(),
            subscriptionService: StoreKitSubscriptionService(),
            catalog: .bundled(),
            storageBucket: bucket ?? "",
            recents: RecentExamsStore(),
            notifications: SystemNotificationService(),
            inboxReader: FirebaseInboxReader(),
            notificationAdmin: FirebaseNotificationAdminService(),
            deviceRegistrar: FirebaseDeviceRegistrar(),
            notificationSettingsService: FirebaseNotificationSettingsService(),
            loginDiagnostics: FirebaseLoginDiagnosticsService(),
            notificationEventReporter: FirebaseNotificationEventReporter()
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
    /// With `-ViFiMockData`: starts on the blocking required-update screen, to exercise the update gate.
    static let forceUpdate = "-ViFiForceUpdate"
    /// With `-ViFiMockData`: starts with no stored profile, on the blocking profile-completion screen.
    static let profileIncomplete = "-ViFiProfileIncomplete"
    /// With `-ViFiMockData`: reports the signed-in user as an admin, to exercise the moderation tools.
    static let admin = "-ViFiAdmin"
    /// With `-ViFiMockData`: starts the user with no coins, to exercise the locked-exam / earn-coins prompt.
    static let noCoins = "-ViFiNoCoins"
    /// With `-ViFiMockData`: forces the first-launch onboarding tour to show (mock otherwise starts past it).
    static let showOnboarding = "-ViFiShowOnboarding"
    /// With `-ViFiMockData`: reports notification permission as not-yet-asked, so the permission flow shows (step
    /// 1/2; "Bildirimleri Aç" leads on to step 2/2, the campaign consent).
    static let notificationsPrompt = "-ViFiNotificationsPrompt"
    /// With `-ViFiMockData`: reports notification permission as denied in the system settings.
    static let notificationsDenied = "-ViFiNotificationsDenied"
    /// With `-ViFiMockData`: starts as if the user declined the permission step 31 days ago (so the contextual
    /// re-ask after an exam submission is due) and notifications are only provisionally allowed.
    static let notificationsReask = "-ViFiNotificationsReask"
    /// With `-ViFiMockData`: starts as if the user declined the campaign consent 31 days ago (so the re-ask is
    /// offered when the inbox opens); campaigns are off.
    static let consentReask = "-ViFiConsentReask"
    /// With `-ViFiMockData`: starts with an active premium subscription (whole archive unlocked, coins hidden).
    static let subscribed = "-ViFiSubscribed"
    /// With `-ViFiMockData` and the notification id as the next argument: starts as if that push had been
    /// tapped, so the inbox opens on it once the app is past its gates.
    static let openNotification = "-ViFiOpenNotification"
    #endif
}

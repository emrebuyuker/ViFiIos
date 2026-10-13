#if DEBUG
import Foundation
import os

// MARK: - Environment

extension AppEnvironment {
    /// Bundled sample data with no Firebase or network access, for previews, UI tests and demos.
    ///
    /// Recents are stored in a separate defaults suite that starts empty on every launch. The user is signed in
    /// unless `arguments` contain `-ViFiSignedOut`.
    static func mock(arguments: [String] = []) -> AppEnvironment {
        // The onboarding tour starts hidden so the existing UI tests land straight on the home list;
        // `-ViFiShowOnboarding` forces it visible to exercise the tour itself.
        let onboardingDefaults = UserDefaults.mockSuite
        OnboardingStore.seed(seen: !arguments.contains(LaunchArgument.showOnboarding), into: onboardingDefaults)
        return AppEnvironment(
            repository: MockArchiveRepository(),
            fileLoader: RemoteFileLoader(),
            updateChecker: StubUpdateChecker(status: mockUpdateStatus(arguments: arguments)),
            analytics: NoOpAnalyticsTracker(),
            auth: MockAuthService(
                isSignedIn: !arguments.contains(LaunchArgument.signedOut),
                isAdmin: arguments.contains(LaunchArgument.admin)
            ),
            profileService: MockProfileService(profile: mockProfile(arguments: arguments)),
            submissionService: MockExamSubmissionService(),
            rewardsConfig: StubRewardsConfigReader(),
            walletReader: StubWalletReader(
                wallet: CoinWallet(balance: arguments.contains(LaunchArgument.noCoins) ? 0 : 120, updatedAt: nil)
            ),
            moderationService: MockModerationService(),
            unlockService: MockExamUnlockService(),
            unlocksReader: StubUnlocksReader(),
            catalog: .bundled(),
            recents: RecentExamsStore(defaults: .mockSuite),
            // Keep the prefetch throttle out of the real defaults, so a mock/UI-test run never suppresses a
            // later live warm (the mock repository's prefetch is a no-op anyway).
            prefetcherDefaults: .mockSuite,
            onboardingDefaults: onboardingDefaults
        )
    }

    /// No stored profile with `-ViFiProfileIncomplete` (the completion gate is shown), otherwise a sample one
    /// (so the archive opens straight away).
    private static func mockProfile(arguments: [String]) -> UserProfile? {
        arguments.contains(LaunchArgument.profileIncomplete) ? nil : .mockDefault
    }

    /// A blocking required update with `-ViFiForceUpdate`, otherwise up to date.
    private static func mockUpdateStatus(arguments: [String]) -> AppUpdateStatus {
        guard arguments.contains(LaunchArgument.forceUpdate) else { return .upToDate }
        let storeURL = URL(string: "https://apps.apple.com") ?? URL(filePath: "/")
        return .required(AppUpdate(version: "99.0.0", storeURL: storeURL, message: nil))
    }
}

private extension UserDefaults {
    static let mockSuiteName = "ViFi.mock"

    /// Kept apart from the real recents and wiped once per process, so every launch starts clean.
    static let mockSuite: UserDefaults = {
        guard let defaults = UserDefaults(suiteName: mockSuiteName) else {
            Logger.app.fault("Could not open the \(mockSuiteName, privacy: .public) defaults suite")
            return .standard
        }
        defaults.removePersistentDomain(forName: mockSuiteName)
        return defaults
    }()
}

// MARK: - Archive

/// Serves a small fixed archive from memory.
///
/// The tree mirrors the Realtime Database shape exactly — name placeholder leaves included — and is
/// parsed by `ArchiveParser`, so previews and UI tests exercise the production parsing code.
final class MockArchiveRepository: ArchiveRepository {
    private let latency: Duration
    private let failing: Bool
    private let tree: [String: Any]

    /// - Parameters:
    ///   - latency: Simulated network delay of every call.
    ///   - failing: Makes every call throw `ArchiveError.offline`.
    init(latency: Duration = .milliseconds(300), failing: Bool = false) {
        self.latency = latency
        self.failing = failing
        tree = MockArchive.makeTree()
    }

    func items(at path: ArchivePath) async throws -> [ArchiveItem] {
        let node = try await node(at: path)
        return ArchiveParser.items(in: node, at: path)
    }

    func document(at path: ArchivePath) async throws -> ExamDocument {
        let node = try await node(at: path)
        guard let document = ArchiveParser.document(in: node, at: path) else {
            throw ArchiveError.notFound
        }
        return document
    }

    /// The raw node at `path`, after the simulated latency.
    private func node(at path: ArchivePath) async throws -> Any {
        if latency > .zero {
            try await Task.sleep(for: latency)
        }
        if failing {
            throw ArchiveError.offline
        }

        var node: Any = tree
        for component in path.components {
            guard let child = (node as? [String: Any])?[component] else {
                throw ArchiveError.notFound
            }
            node = child
        }
        return node
    }
}

extension ArchivePath {
    /// `MÜHENDİSLİK MATEMATİĞİ` in the mock archive: a lesson with an image exam and a PDF exam.
    static let mockLesson = ArchivePath(components: [
        "BOZOK ÜNİVERSİTESİ",
        "MÜHENDİSLİK MİMARLIK FAKÜLTESİ",
        "BİLGİSAYAR MÜHENDİSLİĞİ",
        "MÜHENDİSLİK MATEMATİĞİ",
    ])
    /// A three-page image exam of the mock archive.
    static let mockImagesExam = mockLesson.appending("2019 FİNAL")
    /// A single-file PDF exam of the mock archive.
    static let mockPDFExam = mockLesson.appending("2018 VİZE")
    /// A lesson of the mock archive without exams (empty state).
    static let mockEmptyLesson = ArchivePath(components: [
        "KOCAELİ ÜNİVERSİTESİ",
        "MÜHENDİSLİK FAKÜLTESİ",
        "MATEMATİK BÖLÜMÜ",
        "TOPOLOJİ 2",
    ])
}

/// Builds the mock database tree.
private enum MockArchive {
    static func makeTree() -> [String: Any] {
        let pages = [
            sampleFile("sample-page-1", withExtension: "jpg"),
            sampleFile("sample-page-2", withExtension: "jpg"),
            sampleFile("sample-page-3", withExtension: "jpg"),
        ].compactMap { $0 }
        let pdf = [sampleFile("sample-exam", withExtension: "pdf")].compactMap { $0 }

        return tree([
            node(.university, "BOZOK ÜNİVERSİTESİ", [
                node(.faculty, "MÜHENDİSLİK MİMARLIK FAKÜLTESİ", [
                    node(.department, "BİLGİSAYAR MÜHENDİSLİĞİ", [
                        node(.lesson, "MÜHENDİSLİK MATEMATİĞİ", [
                            // More than two exams, so the newest two are locked (the oldest two stay free).
                            exam("2023 VİZE", .images, files: pages),
                            exam("2022 FİNAL", .pdf, files: pdf),
                            exam("2019 FİNAL", .images, files: pages),
                            exam("2018 VİZE", .pdf, files: pdf),
                        ]),
                    ]),
                ]),
            ]),
            node(.university, "KOCAELİ ÜNİVERSİTESİ", [
                node(.faculty, "MÜHENDİSLİK FAKÜLTESİ", [
                    node(.department, "MATEMATİK BÖLÜMÜ", [
                        node(.lesson, "TOPOLOJİ 1", [
                            exam("2002 VİZE", .images, files: Array(pages.prefix(2))),
                        ]),
                        node(.lesson, "TOPOLOJİ 2"),
                    ]),
                ]),
            ]),
            node(.university, "KÜTAHYA DUMLUPINAR ÜNİVERSİTESİ", [
                node(.faculty, "FEN EDEBİYAT FAKÜLTESİ", [
                    node(.department, "FİZİK BÖLÜMÜ", [
                        node(.lesson, "KUANTUM FİZİĞİ", [
                            exam("2020 BÜTÜNLEME", .pdf, files: pdf),
                        ]),
                    ]),
                ]),
            ]),
            node(.university, "SAKARYA ÜNİVERSİTESİ", [
                node(.faculty, "İŞLETME FAKÜLTESİ", [
                    node(.department, "İŞLETME BÖLÜMÜ", [
                        node(.lesson, "MUHASEBE", [
                            // Only the name placeholder: listed, but has no files to open.
                            exam("2021 VİZE", .images, files: []),
                        ]),
                    ]),
                ]),
            ]),
        ])
    }

    private typealias Entry = (key: String, value: Any)

    private static func tree(_ entries: [Entry]) -> [String: Any] {
        Dictionary(entries.map { ($0.key, $0.value) }, uniquingKeysWith: { _, last in last })
    }

    /// An archive node: its children plus the string leaf holding its own name, like the real database.
    private static func node(_ level: ArchiveLevel, _ name: String, _ children: [Entry] = []) -> Entry {
        var value = tree(children)
        value[level.placeholderKey] = name
        return (name, value)
    }

    /// An exam node: `<JPG|PDF>/<pushId>/downloadURL`, with push ids sorting in page order.
    private static func exam(_ name: String, _ kind: ExamKind, files: [URL]) -> Entry {
        let uploads = files.enumerated().map { index, url -> Entry in
            let pushID = "-ViFiMock" + String(index + 1).leftPadded(toLength: 4, with: "0")
            return (pushID, ["downloadURL": url.absoluteString])
        }
        var children: [Entry] = []
        if !uploads.isEmpty {
            children.append((kind.rawValue, tree(uploads)))
        }
        return node(.exam, name, children)
    }

    /// A bundled sample, or `nil` (logged) when it is missing so the archive still loads without it.
    private static func sampleFile(_ name: String, withExtension fileExtension: String) -> URL? {
        let url = Bundle.main.url(forResource: name, withExtension: fileExtension)
            ?? Bundle.main.url(forResource: name, withExtension: fileExtension, subdirectory: "SampleExams")
        if url == nil {
            let fileName = "\(name).\(fileExtension)"
            Logger.archive.error("Mock sample \(fileName, privacy: .public) is missing from the bundle; skipping it")
        }
        return url
    }
}

private extension ArchiveLevel {
    /// The key under which the real database stores a node's own name.
    var placeholderKey: String {
        switch self {
        case .university: "uniname"
        case .faculty: "fakname"
        case .department: "bolname"
        case .lesson: "lessonname"
        case .exam: "imagename"
        }
    }
}

private extension String {
    func leftPadded(toLength length: Int, with pad: Character) -> String {
        String(repeating: pad, count: max(0, length - count)) + self
    }
}

// MARK: - Auth

/// Phone sign-in without Firebase: any Turkish mobile number gets a code, and the code is always `111111`.
final class MockAuthService: AuthServicing {
    /// The only code accepted.
    static let validCode = "111111"
    /// The user signed in at launch.
    static let defaultUser = AuthUser(id: "mock-user", phoneNumber: "+905321234567")

    private(set) var currentUser: AuthUser?

    private let latency: Duration
    private let requiresRecentLoginForDeletion: Bool
    private let admin: Bool
    private var isRecentlyAuthenticated = false
    /// Numbers that codes were sent to, by verification id.
    private var pendingNumbers: [String: String] = [:]
    private var continuations: [UUID: AsyncStream<AuthUser?>.Continuation] = [:]

    /// - Parameters:
    ///   - isSignedIn: Starts with `defaultUser` signed in.
    ///   - latency: Simulated network delay of every call.
    ///   - requiresRecentLoginForDeletion: Deleting needs a fresh code first, like an old Firebase session.
    ///   - isAdmin: Reports the user as an admin, to exercise the in-app moderation tools.
    init(
        isSignedIn: Bool = true,
        latency: Duration = .milliseconds(300),
        requiresRecentLoginForDeletion: Bool = false,
        isAdmin: Bool = false
    ) {
        currentUser = isSignedIn ? Self.defaultUser : nil
        self.latency = latency
        self.requiresRecentLoginForDeletion = requiresRecentLoginForDeletion
        admin = isAdmin
    }

    func isCurrentUserAdmin() async -> Bool {
        currentUser != nil && admin
    }

    func userChanges() -> AsyncStream<AuthUser?> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuations[id] = continuation
            continuation.yield(currentUser)
            continuation.onTermination = { @Sendable [weak self] _ in
                Task { @MainActor in
                    self?.continuations[id] = nil
                }
            }
        }
    }

    func sendVerificationCode(to phoneNumber: String) async throws -> String {
        try await simulateLatency()
        guard PhoneNumber(e164: phoneNumber) != nil else { throw AuthError.invalidPhoneNumber }
        let verificationID = "mock-verification-\(UUID().uuidString)"
        pendingNumbers[verificationID] = phoneNumber
        return verificationID
    }

    @discardableResult
    func signIn(verificationID: String, code: String) async throws -> AuthUser {
        let phoneNumber = try await verify(verificationID: verificationID, code: code)
        let user = AuthUser(id: Self.defaultUser.id, phoneNumber: phoneNumber)
        isRecentlyAuthenticated = true
        update(user)
        return user
    }

    func reauthenticate(verificationID: String, code: String) async throws {
        _ = try await verify(verificationID: verificationID, code: code)
        guard currentUser != nil else { throw AuthError.notSignedIn }
        isRecentlyAuthenticated = true
    }

    func signOut() throws {
        update(nil)
    }

    func deleteAccount() async throws {
        try await simulateLatency()
        guard currentUser != nil else { throw AuthError.notSignedIn }
        guard isRecentlyAuthenticated || !requiresRecentLoginForDeletion else { throw AuthError.requiresRecentLogin }
        update(nil)
    }

    func canHandle(_ url: URL) -> Bool {
        false
    }

    // MARK: - Private

    /// The number the code was sent to, once `code` is the valid one.
    private func verify(verificationID: String, code: String) async throws -> String {
        try await simulateLatency()
        guard let phoneNumber = pendingNumbers[verificationID] else { throw AuthError.codeExpired }
        guard code == Self.validCode else { throw AuthError.invalidCode }
        pendingNumbers[verificationID] = nil
        return phoneNumber
    }

    private func update(_ user: AuthUser?) {
        if user == nil {
            isRecentlyAuthenticated = false
        }
        currentUser = user
        for continuation in continuations.values {
            continuation.yield(user)
        }
    }

    private func simulateLatency() async throws {
        if latency > .zero {
            try await Task.sleep(for: latency)
        }
    }
}

// MARK: - Profile

/// A sample profile for the signed-in mock user, so the archive opens without the completion gate.
extension UserProfile {
    static let mockDefault = UserProfile(
        name: "Ayşe",
        surname: "Yılmaz",
        university: "Boğaziçi Üniversitesi",
        universityId: "bogazici-universitesi",
        universityIsCustom: false,
        faculty: "Mühendislik Fakültesi",
        facultyId: "muhendislik-fakultesi",
        facultyIsCustom: false,
        department: "Bilgisayar Mühendisliği",
        departmentId: "bilgisayar-muhendisligi",
        departmentIsCustom: false,
        gender: .female,
        phoneNumber: MockAuthService.defaultUser.phoneNumber ?? "+905321234567"
    )
}

/// Profile storage in memory, for previews and UI tests.
final class MockProfileService: ProfileServicing {
    private var profile: UserProfile?
    private let latency: Duration

    /// - Parameters:
    ///   - profile: The stored profile, or `nil` to start on the completion gate.
    ///   - latency: Simulated network delay of every call.
    init(profile: UserProfile?, latency: Duration = .milliseconds(300)) {
        self.profile = profile
        self.latency = latency
    }

    func loadProfile(uid: String) async throws -> UserProfile? {
        try await simulateLatency()
        return profile
    }

    func saveProfile(_ profile: UserProfile, uid: String) async throws {
        try await simulateLatency()
        self.profile = profile
    }

    func deleteProfile(uid: String) async throws {
        try await simulateLatency()
        profile = nil
    }

    private func simulateLatency() async throws {
        if latency > .zero {
            try await Task.sleep(for: latency)
        }
    }
}

// MARK: - Submissions

/// In-memory exam submissions, for previews and UI tests. Records every submitted exam; never touches Firebase.
final class MockExamSubmissionService: ExamSubmissionServicing {
    private(set) var submitted: [ExamSubmission] = []
    private let latency: Duration
    private let failing: Bool

    /// - Parameters:
    ///   - latency: Simulated network delay of every call.
    ///   - failing: Makes every call throw `ExamSubmissionError.offline`.
    init(latency: Duration = .milliseconds(300), failing: Bool = false) {
        self.latency = latency
        self.failing = failing
    }

    func submit(_ submission: ExamSubmission, ownerId: String) async throws {
        if latency > .zero {
            try await Task.sleep(for: latency)
        }
        if failing {
            throw ExamSubmissionError.offline
        }
        submitted.append(submission)
    }
}

// MARK: - Moderation

/// In-memory moderation for previews and UI tests: a small pending queue; approving or rejecting removes an
/// item. The sample files reference pending paths that do not resolve off Firebase, so the preview shows its
/// error state in sample mode (the queue, approve and reject flows are what the UI tests exercise).
final class MockModerationService: ModerationServicing {
    private var pending: [ExamSubmissionRecord]
    private let latency: Duration

    init(pending: [ExamSubmissionRecord] = MockModerationService.samples, latency: Duration = .milliseconds(300)) {
        self.pending = pending
        self.latency = latency
    }

    static let samples: [ExamSubmissionRecord] = [
        ExamSubmissionRecord(
            id: "sub-1", ownerId: "mock-user",
            university: "Boğaziçi Üniversitesi", faculty: "Mühendislik Fakültesi",
            department: "Bilgisayar Mühendisliği", lesson: "Ayrık Matematik", exam: "2023 VİZE",
            kind: .images, status: "pending", createdAt: Date(timeIntervalSince1970: 1_760_000_000),
            files: [
                SubmissionFileRef(storagePath: "pending/mock-user/sub-1/1.jpg", order: 1),
                SubmissionFileRef(storagePath: "pending/mock-user/sub-1/2.jpg", order: 2),
            ]
        ),
        ExamSubmissionRecord(
            id: "sub-2", ownerId: "mock-user",
            university: "Sakarya Üniversitesi", faculty: "İşletme Fakültesi",
            department: "İşletme", lesson: "Muhasebe", exam: "2022 FİNAL",
            kind: .pdf, status: "pending", createdAt: Date(timeIntervalSince1970: 1_759_000_000),
            files: [SubmissionFileRef(storagePath: "pending/mock-user/sub-2/1.pdf", order: 1)]
        ),
    ]

    func pendingSubmissions() async throws -> [ExamSubmissionRecord] {
        try? await Task.sleep(for: latency)
        return pending
    }

    func approve(_ record: ExamSubmissionRecord) async throws -> ApprovalResult {
        try? await Task.sleep(for: latency)
        pending.removeAll { $0.id == record.id }
        return ApprovalResult(tier: .newUniversity, coins: 500, publishedExamId: "pub-\(record.id)")
    }

    func reject(_ record: ExamSubmissionRecord, reason: String?) async throws {
        try? await Task.sleep(for: latency)
        pending.removeAll { $0.id == record.id }
    }

    func deleteExam(at path: ArchivePath) async throws {
        try? await Task.sleep(for: latency)
    }
}

// MARK: - Analytics & updates

/// Drops analytics events (logged at debug level so they can be inspected while developing).
final class NoOpAnalyticsTracker: AnalyticsTracking {
    init() {}

    func track(_ event: AnalyticsEvent) {
        Logger.app.debug("Analytics event (not sent): \(String(describing: event), privacy: .public)")
    }
}

/// Reports a fixed reward config, once (sample per-tier coin amounts for previews and UI tests).
final class StubRewardsConfigReader: RewardsConfigReading {
    private let config: RewardsConfig?

    init(config: RewardsConfig? = RewardsConfig(examUploadCoins: 10, tiers: [
        .newUniversity: 500,
        .newFaculty: 300,
        .newDepartment: 200,
        .newCourse: 120,
        .newExam: 60,
        .duplicate: 10,
    ])) {
        self.config = config
    }

    func rewardsChanges() -> AsyncStream<RewardsConfig?> {
        let config = config
        return AsyncStream { continuation in
            continuation.yield(config)
            continuation.finish()
        }
    }
}

/// Reports a fixed coin balance, once (a sample balance for previews and UI tests).
final class StubWalletReader: WalletReading {
    private let wallet: CoinWallet

    init(wallet: CoinWallet = CoinWallet(balance: 120, updatedAt: nil)) {
        self.wallet = wallet
    }

    func walletChanges(uid: String) -> AsyncStream<CoinWallet> {
        let wallet = wallet
        return AsyncStream { continuation in
            continuation.yield(wallet)
            continuation.finish()
        }
    }
}

/// Serves a fixed set of unlocked exams, for previews and UI tests.
final class StubUnlocksReader: UnlocksReading {
    private let ids: Set<String>

    init(ids: Set<String> = []) {
        self.ids = ids
    }

    func unlockedExamIds(uid: String) async throws -> Set<String> {
        ids
    }
}

/// In-memory exam unlocking for previews and UI tests: succeeds unless `failure` is set.
final class MockExamUnlockService: ExamUnlockServicing {
    private let latency: Duration
    private let failure: ExamUnlockError?
    private(set) var unlockedExamIds: [String] = []

    init(latency: Duration = .milliseconds(300), failure: ExamUnlockError? = nil) {
        self.latency = latency
        self.failure = failure
    }

    func unlock(examId: String) async throws -> ExamUnlockResult {
        try? await Task.sleep(for: latency)
        if let failure {
            throw failure
        }
        unlockedExamIds.append(examId)
        return ExamUnlockResult(balance: 20, alreadyUnlocked: false)
    }
}

/// Reports a fixed update status, once.
final class StubUpdateChecker: AppUpdateChecking {
    private let status: AppUpdateStatus

    init(status: AppUpdateStatus = .upToDate) {
        self.status = status
    }

    func statusChanges() -> AsyncStream<AppUpdateStatus> {
        let status = status
        return AsyncStream { continuation in
            continuation.yield(status)
            continuation.finish()
        }
    }
}
#endif

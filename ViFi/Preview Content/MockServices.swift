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
        AppEnvironment(
            repository: MockArchiveRepository(),
            fileLoader: RemoteFileLoader(),
            updateChecker: StubUpdateChecker(status: mockUpdateStatus(arguments: arguments)),
            analytics: NoOpAnalyticsTracker(),
            auth: MockAuthService(isSignedIn: !arguments.contains(LaunchArgument.signedOut)),
            recents: RecentExamsStore(defaults: .mockSuite)
        )
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
    private var isRecentlyAuthenticated = false
    /// Numbers that codes were sent to, by verification id.
    private var pendingNumbers: [String: String] = [:]
    private var continuations: [UUID: AsyncStream<AuthUser?>.Continuation] = [:]

    /// - Parameters:
    ///   - isSignedIn: Starts with `defaultUser` signed in.
    ///   - latency: Simulated network delay of every call.
    ///   - requiresRecentLoginForDeletion: Deleting needs a fresh code first, like an old Firebase session.
    init(isSignedIn: Bool = true, latency: Duration = .milliseconds(300), requiresRecentLoginForDeletion: Bool = false) {
        currentUser = isSignedIn ? Self.defaultUser : nil
        self.latency = latency
        self.requiresRecentLoginForDeletion = requiresRecentLoginForDeletion
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

// MARK: - Analytics & updates

/// Drops analytics events (logged at debug level so they can be inspected while developing).
final class NoOpAnalyticsTracker: AnalyticsTracking {
    init() {}

    func track(_ event: AnalyticsEvent) {
        Logger.app.debug("Analytics event (not sent): \(String(describing: event), privacy: .public)")
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

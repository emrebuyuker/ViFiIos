import Foundation
import os
import Testing
@testable import ViFi

// MARK: - Archive repository

/// An `ArchiveRepository` that answers with scripted replies and records every request.
///
/// Each reply list answers successive calls in order; once it runs out, its last reply is repeated.
final class StubArchiveRepository: ArchiveRepository {
    var itemsReplies: [Result<[ArchiveItem], any Error>]
    var documentReplies: [Result<ExamDocument, any Error>]
    /// When set, every request waits at the gate before it is answered.
    var gate: AsyncGate?

    private(set) var requestedItemPaths: [ArchivePath] = []
    private(set) var requestedDocumentPaths: [ArchivePath] = []

    init(
        items: [Result<[ArchiveItem], any Error>] = [.success([])],
        documents: [Result<ExamDocument, any Error>] = [.failure(ArchiveError.notFound)],
        gate: AsyncGate? = nil
    ) {
        itemsReplies = items
        documentReplies = documents
        self.gate = gate
    }

    func items(at path: ArchivePath) async throws -> [ArchiveItem] {
        let call = requestedItemPaths.count
        requestedItemPaths.append(path)
        await gate?.pass()
        return try Self.reply(to: call, from: itemsReplies).get()
    }

    func document(at path: ArchivePath) async throws -> ExamDocument {
        let call = requestedDocumentPaths.count
        requestedDocumentPaths.append(path)
        await gate?.pass()
        return try Self.reply(to: call, from: documentReplies).get()
    }

    /// Archive change notifications the test drives; finishes immediately when unset.
    var changes: AsyncStream<Void>?

    func archiveChanges() -> AsyncStream<Void> {
        changes ?? AsyncStream { $0.finish() }
    }

    private static func reply<Value>(
        to call: Int,
        from replies: [Result<Value, any Error>]
    ) -> Result<Value, any Error> {
        guard !replies.isEmpty else {
            return .failure(ArchiveError.unknown(message: "No stubbed reply for call \(call)."))
        }
        return replies[min(call, replies.count - 1)]
    }
}

// MARK: - Async gate

/// Holds async calls until the test opens it, so a test can act while a request is still in flight.
final class AsyncGate {
    /// Number of calls that reached the gate so far.
    private(set) var arrivals = 0

    private var isOpen = false
    private var heldCalls: [CheckedContinuation<Void, Never>] = []
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []

    /// Records the arrival, then suspends until `open()` unless the gate is already open.
    func pass() async {
        arrivals += 1
        Self.resumeAll(of: &arrivalWaiters)
        guard !isOpen else { return }
        await withCheckedContinuation { heldCalls.append($0) }
    }

    /// Returns once at least one call has reached the gate.
    func waitForArrival() async {
        guard arrivals == 0 else { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }

    /// Releases the held calls and lets every later call straight through.
    func open() {
        isOpen = true
        Self.resumeAll(of: &heldCalls)
    }

    private static func resumeAll(of continuations: inout [CheckedContinuation<Void, Never>]) {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

// MARK: - Analytics

/// Records tracked analytics events in order.
final class AnalyticsSpy: AnalyticsTracking {
    private(set) var events: [AnalyticsEvent] = []

    func track(_ event: AnalyticsEvent) {
        events.append(event)
    }
}

// MARK: - Auth

/// An `AuthServicing` that answers with scripted replies and records every call.
///
/// Each reply list answers successive calls in order; once it runs out, its last reply is repeated.
/// Successful sign-ins, sign-outs and deletions update `currentUser` and notify `userChanges()` like the real
/// service does.
final class StubAuthService: AuthServicing {
    enum Call: Equatable {
        case sendCode(phoneNumber: String)
        case signIn(verificationID: String, code: String)
        case reauthenticate(verificationID: String, code: String)
        case signOut
        case deleteAccount
    }

    var currentUser: AuthUser?
    var sendReplies: [Result<String, any Error>] = [.success("verification-1")]
    var signInReplies: [Result<AuthUser, any Error>] = [.success(Fixture.user)]
    var reauthenticateReplies: [Result<Void, any Error>] = [.success(())]
    var deleteReplies: [Result<Void, any Error>] = [.success(())]
    var signOutError: (any Error)?
    /// When set, every asynchronous call waits at the gate before it is answered.
    var gate: AsyncGate?

    private(set) var calls: [Call] = []
    private var continuations: [AsyncStream<AuthUser?>.Continuation] = []

    init(currentUser: AuthUser? = nil) {
        self.currentUser = currentUser
    }

    /// The codes sent so far, as the numbers they were sent to.
    var sentNumbers: [String] {
        calls.compactMap { if case let .sendCode(number) = $0 { number } else { nil } }
    }

    /// The number of calls equal to `call`.
    func count(of call: Call) -> Int {
        calls.count(where: { $0 == call })
    }

    /// Number of `userChanges()` streams that were requested and not finished by `finishUserChanges()`.
    var observerCount: Int {
        continuations.count
    }

    func userChanges() -> AsyncStream<AuthUser?> {
        let (stream, continuation) = AsyncStream.makeStream(of: AuthUser?.self)
        continuation.yield(currentUser)
        continuations.append(continuation)
        return stream
    }

    /// Reports a sign-in or sign-out that happened elsewhere (e.g. the session was revoked).
    func emit(_ user: AuthUser?) {
        currentUser = user
        for continuation in continuations {
            continuation.yield(user)
        }
    }

    /// Ends every `userChanges()` stream.
    func finishUserChanges() {
        for continuation in continuations {
            continuation.finish()
        }
        continuations.removeAll()
    }

    func sendVerificationCode(to phoneNumber: String) async throws -> String {
        let call = calls.count(where: { if case .sendCode = $0 { true } else { false } })
        calls.append(.sendCode(phoneNumber: phoneNumber))
        await gate?.pass()
        return try Self.reply(to: call, from: sendReplies).get()
    }

    @discardableResult
    func signIn(verificationID: String, code: String) async throws -> AuthUser {
        let call = calls.count(where: { if case .signIn = $0 { true } else { false } })
        calls.append(.signIn(verificationID: verificationID, code: code))
        await gate?.pass()
        let user = try Self.reply(to: call, from: signInReplies).get()
        emit(user)
        return user
    }

    func reauthenticate(verificationID: String, code: String) async throws {
        let call = calls.count(where: { if case .reauthenticate = $0 { true } else { false } })
        calls.append(.reauthenticate(verificationID: verificationID, code: code))
        await gate?.pass()
        try Self.reply(to: call, from: reauthenticateReplies).get()
    }

    func signOut() throws {
        calls.append(.signOut)
        if let signOutError {
            throw signOutError
        }
        emit(nil)
    }

    func deleteAccount() async throws {
        let call = calls.count(where: { $0 == .deleteAccount })
        calls.append(.deleteAccount)
        await gate?.pass()
        try Self.reply(to: call, from: deleteReplies).get()
        emit(nil)
    }

    func canHandle(_ url: URL) -> Bool {
        false
    }

    private static func reply<Value>(
        to call: Int,
        from replies: [Result<Value, any Error>]
    ) -> Result<Value, any Error> {
        guard !replies.isEmpty else {
            return .failure(AuthError.unknown(message: "No stubbed reply for call \(call)."))
        }
        return replies[min(call, replies.count - 1)]
    }
}

/// A `RequestAuthorizing` that adds fixed credentials and records every request for them.
///
/// The ID token is `cached-token`, or `refreshed-token` after a forced refresh; the App Check token is
/// `app-check-token`.
final class StubRequestAuthorizer: RequestAuthorizing {
    struct Call: Equatable {
        let url: URL
        let forceRefresh: Bool
    }

    /// When set, every request fails with it (e.g. `ArchiveError.permissionDenied` when signed out).
    var failure: (any Error)?
    /// When set, every request waits at the gate before it is answered.
    var gate: AsyncGate?

    private(set) var calls: [Call] = []

    func authorizedRequest(for url: URL, forceRefresh: Bool) async throws -> URLRequest {
        calls.append(Call(url: url, forceRefresh: forceRefresh))
        await gate?.pass()
        if let failure {
            throw failure
        }
        var request = URLRequest(url: url)
        request.setValue(forceRefresh ? "Firebase refreshed-token" : "Firebase cached-token", forHTTPHeaderField: "Authorization")
        request.setValue("app-check-token", forHTTPHeaderField: "X-Firebase-AppCheck")
        return request
    }
}

// MARK: - Time & waiting

/// A clock the test moves by hand, to read through `now`.
final class TestClock {
    private(set) var date: Date

    init(_ date: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.date = date
    }

    /// The injectable clock function.
    var now: () -> Date {
        { [self] in date }
    }

    func advance(by interval: TimeInterval) {
        date = date.addingTimeInterval(interval)
    }
}

/// Whether `condition` becomes true within `timeout`, polled between yields (for state that changes in
/// tasks the test cannot await).
func eventually(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

// MARK: - Isolated storage

/// A `UserDefaults` suite private to one test; its contents are deleted when it is released.
final class TemporaryDefaults {
    let defaults: UserDefaults
    private let suiteName: String

    init() throws {
        suiteName = "ViFiTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        // Through `.standard`: `deinit` is nonisolated, and `UserDefaults` is not `Sendable` on every SDK.
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }
}

/// A bundle on disk holding only an `Info.plist`, to control the identifier and version a component reads.
///
/// Every instance gets a unique bundle identifier, which tests can use as a key for stubbed requests.
/// The directory is deleted when the instance is released.
final class TemporaryBundle {
    let bundle: Bundle
    let identifier: String
    private let directory: URL

    init(version: String) throws {
        identifier = "com.BuyukerYazilim.ViFi2.tests.\(UUID().uuidString)"
        directory = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).bundle", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
            "CFBundlePackageType": "BNDL",
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: directory.appending(path: "Info.plist"))
        bundle = try #require(Bundle(url: directory))
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - URL loading

/// Answers requests with canned replies registered per URL, so tests never touch the network.
///
/// Replies live in process-wide tables keyed by URL: tests running in parallel stay independent as
/// long as each one registers a URL of its own.
nonisolated final class StubURLProtocol: URLProtocol {
    enum Reply: Sendable {
        case response(statusCode: Int, body: Data)
        case failure(URLError.Code)
    }

    /// Replies answered in order (the last one repeats), and the requests that were received.
    private struct Script {
        var replies: [Reply]
        var requests: [URLRequest] = []
    }

    private static let replies = OSAllocatedUnfairLock(initialState: [String: Reply]())
    private static let scripts = OSAllocatedUnfairLock(initialState: [String: Script]())

    /// An ephemeral session whose requests to `url` get `reply`; any other request fails.
    static func session(answering url: URL, with reply: Reply) -> URLSession {
        let key = url.absoluteString
        replies.withLock { $0[key] = reply }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// A session whose successive requests to `url` get `replies` in order (the last one repeats), with a log of
    /// the requests as they arrived (headers included). The session has an in-memory response cache.
    static func session(answering url: URL, inOrder replies: [Reply]) -> (session: URLSession, log: RequestLog) {
        let key = url.absoluteString
        scripts.withLock { $0[key] = Script(replies: replies) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.urlCache = URLCache(memoryCapacity: 20 * 1024 * 1024, diskCapacity: 0)
        return (URLSession(configuration: configuration), RequestLog(key: key))
    }

    fileprivate static func requests(for key: String) -> [URLRequest] {
        scripts.withLock { $0[key]?.requests ?? [] }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        switch Self.nextReply(for: url, request: request) {
        case let .response(statusCode, body):
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        }
    }

    override func stopLoading() {}

    /// The reply for `request`, recording the request when its URL has a script.
    private static func nextReply(for url: URL, request: URLRequest) -> Reply? {
        let key = url.absoluteString
        let scripted: Reply?? = scripts.withLock { scripts in
            guard var script = scripts[key], !script.replies.isEmpty else { return nil }
            let index = min(script.requests.count, script.replies.count - 1)
            script.requests.append(request)
            scripts[key] = script
            return .some(script.replies[index])
        }
        if let scripted {
            return scripted
        }
        return replies.withLock { $0[key] }
    }
}

/// The requests a scripted `StubURLProtocol` URL received, oldest first.
nonisolated final class RequestLog: Sendable {
    private let key: String

    fileprivate init(key: String) {
        self.key = key
    }

    var requests: [URLRequest] {
        StubURLProtocol.requests(for: key)
    }

    var count: Int {
        requests.count
    }

    /// The value of header `name` on the request at `index`, or `nil`.
    func header(_ name: String, at index: Int) -> String? {
        let requests = requests
        guard requests.indices.contains(index) else { return nil }
        return requests[index].value(forHTTPHeaderField: name)
    }
}

// MARK: - Fixtures

/// Archive values shared by the suites, named after the bundled mock archive.
enum Fixture {
    /// A signed-in user with a Turkish number.
    static let user = AuthUser(id: "user-1", phoneNumber: "+905321234567")
    static let phoneNumber = "+905321234567"

    static let lesson = ArchivePath(components: [
        "BOZOK ÜNİVERSİTESİ",
        "MÜHENDİSLİK MİMARLIK FAKÜLTESİ",
        "BİLGİSAYAR MÜHENDİSLİĞİ",
        "MÜHENDİSLİK MATEMATİĞİ",
    ])
    static let imagesExam = lesson.appending("2019 FİNAL")
    static let pdfExam = lesson.appending("2018 VİZE")

    /// University entries, in the order given.
    static func universities(_ names: [String]) -> [ArchiveItem] {
        names.map { name in
            ArchiveItem(path: ArchivePath(components: [name]), level: .university, childCount: 1, exam: nil)
        }
    }

    /// An exam document with `fileCount` local file URLs.
    static func document(
        kind: ExamKind = .images,
        at path: ArchivePath = imagesExam,
        fileCount: Int = 3
    ) -> ExamDocument {
        let fileExtension = kind == .images ? "jpg" : "pdf"
        let urls = (0..<fileCount).map { index in
            URL(filePath: "/exams/\(path.name ?? "exam")/file-\(index + 1).\(fileExtension)")
        }
        return ExamDocument(path: path, kind: kind, fileURLs: urls)
    }
}

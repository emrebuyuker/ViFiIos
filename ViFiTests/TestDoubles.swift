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
/// Replies live in a process-wide table keyed by URL: tests running in parallel stay independent as
/// long as each one registers a URL of its own.
nonisolated final class StubURLProtocol: URLProtocol {
    enum Reply: Sendable {
        case response(statusCode: Int, body: Data)
        case failure(URLError.Code)
    }

    private static let replies = OSAllocatedUnfairLock(initialState: [String: Reply]())

    /// An ephemeral session whose requests to `url` get `reply`; any other request fails.
    static func session(answering url: URL, with reply: Reply) -> URLSession {
        let key = url.absoluteString
        replies.withLock { $0[key] = reply }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
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
        let key = url.absoluteString
        switch Self.replies.withLock({ $0[key] }) {
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
}

// MARK: - Fixtures

/// Archive values shared by the suites, named after the bundled mock archive.
enum Fixture {
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

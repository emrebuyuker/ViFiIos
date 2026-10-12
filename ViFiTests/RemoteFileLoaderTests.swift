import Foundation
import Testing
import UIKit
@testable import ViFi

// MARK: - Canonical URLs

private enum StorageURL {
    /// A Storage download URL without its query.
    nonisolated static let base = "https://firebasestorage.googleapis.com/v0/b/vifi-831a8.appspot.com/o/pdfs%2Fexam.pdf"
}

@Suite("RemoteFileLoader canonical URLs")
struct RemoteFileLoaderCanonicalURLTests {
    @Test("The token query item is removed and alt=media is kept", arguments: [
        ("\(StorageURL.base)?alt=media&token=abc-123", "\(StorageURL.base)?alt=media"),
        ("\(StorageURL.base)?token=abc-123&alt=media", "\(StorageURL.base)?alt=media"),
        ("\(StorageURL.base)?alt=media&token=abc-123&extra=1", "\(StorageURL.base)?alt=media&extra=1"),
        ("\(StorageURL.base)?token=abc-123", StorageURL.base),
    ])
    func tokenIsRemoved(original: String, expected: String) throws {
        let url = try #require(URL(string: original))

        #expect(RemoteFileLoader.canonicalURL(for: url).absoluteString == expected)
    }

    @Test("A URL without a token is returned as it is", arguments: [
        "\(StorageURL.base)?alt=media",
        StorageURL.base,
        "\(StorageURL.base)?alt=media&tokens=1",
    ])
    func urlWithoutToken(original: String) throws {
        let url = try #require(URL(string: original))

        #expect(RemoteFileLoader.canonicalURL(for: url) == url)
    }

    @Test("The encoded path is kept exactly")
    func encodedPathIsKept() throws {
        let original = "https://firebasestorage.googleapis.com/v0/b/vifi-831a8.appspot.com/o/imagess%2Fa%20b%C3%A7.jpg?alt=media&token=x"
        let url = try #require(URL(string: original))

        let canonical = RemoteFileLoader.canonicalURL(for: url)

        #expect(canonical.absoluteString == "https://firebasestorage.googleapis.com/v0/b/vifi-831a8.appspot.com/o/imagess%2Fa%20b%C3%A7.jpg?alt=media")
    }

    @Test("Credentials are only for objects in the app's own bucket", arguments: [
        ("\(StorageURL.base)?alt=media", true),
        ("https://firebasestorage.googleapis.com/v0/b/other-project.appspot.com/o/pdfs%2Fexam.pdf?alt=media", false),
        ("https://firebasestorage.googleapis.com/v0/b/vifi-831a8.appspot.com.evil/o/pdfs%2Fexam.pdf", false),
        ("http://firebasestorage.googleapis.com/v0/b/vifi-831a8.appspot.com/o/pdfs%2Fexam.pdf", false),
        ("https://example.com/v0/b/vifi-831a8.appspot.com/o/pdfs%2Fexam.pdf", false),
    ])
    func bucketIsChecked(original: String, isAuthorized: Bool) throws {
        let url = try #require(URL(string: original))

        #expect(FirebaseRequestAuthorizer.isObject(url, inBucket: "vifi-831a8.appspot.com") == isAuthorized)
        #expect(!FirebaseRequestAuthorizer.isObject(url, inBucket: ""))
    }

    @Test("URLs with different tokens name the same file")
    func differentTokensAreTheSameFile() throws {
        let first = try #require(URL(string: "\(StorageURL.base)?alt=media&token=first"))
        let second = try #require(URL(string: "\(StorageURL.base)?alt=media&token=second"))
        let none = try #require(URL(string: "\(StorageURL.base)?alt=media"))

        #expect(RemoteFileLoader.canonicalURL(for: first) == RemoteFileLoader.canonicalURL(for: second))
        #expect(RemoteFileLoader.canonicalURL(for: first) == none)
    }

    @Test("Other hosts, schemes and local files are left alone", arguments: [
        "https://example.com/exam.pdf?token=abc",
        "http://firebasestorage.googleapis.com/v0/b/x/o/y?alt=media&token=abc",
        "file:///exams/exam.pdf",
        "https://storage.googleapis.com/vifi/exam.pdf?token=abc",
    ])
    func otherURLsAreUnchanged(original: String) throws {
        let url = try #require(URL(string: original))

        #expect(RemoteFileLoader.canonicalURL(for: url) == url)
    }

    @Test("Only https Firebase Storage URLs are recognised as Storage files")
    func storageURLDetection() throws {
        #expect(try RemoteFileLoader.isFirebaseStorageURL(#require(URL(string: "\(StorageURL.base)?alt=media"))))
        #expect(try !RemoteFileLoader.isFirebaseStorageURL(#require(URL(string: "https://example.com/a.pdf"))))
        #expect(try !RemoteFileLoader.isFirebaseStorageURL(#require(URL(string: "http://firebasestorage.googleapis.com/a"))))
        #expect(!RemoteFileLoader.isFirebaseStorageURL(URL(filePath: "/exams/a.pdf")))
    }
}

// MARK: - Authorized downloads

/// Downloads through `StubURLProtocol` with a `StubRequestAuthorizer`.
///
/// Every test uses file URLs of its own (a random name in the bucket), so the tests can run in parallel.
@Suite("RemoteFileLoader authorization", .timeLimit(.minutes(1)))
final class RemoteFileLoaderAuthorizationTests {
    private let authorizer = StubRequestAuthorizer()
    private let cacheDirectory: URL
    private let body = Data("exam file contents".utf8)

    init() {
        cacheDirectory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    // MARK: - Headers and URL

    @Test("The request carries the ID token and the App Check token and names the file without its token")
    func credentialsAreSent() async throws {
        let file = StorageFile()
        let (session, log) = StubURLProtocol.session(answering: file.canonicalURL, inOrder: [.response(statusCode: 200, body: body)])
        let loader = makeLoader(session: session)

        let local = try await loader.localFile(from: file.url(token: "revoked-token"), fileName: "exam.pdf")

        #expect(try Data(contentsOf: local) == body)
        #expect(log.count == 1)
        #expect(log.header("Authorization", at: 0) == "Firebase cached-token")
        #expect(log.header("X-Firebase-AppCheck", at: 0) == "app-check-token")
        let requestURL = try #require(log.requests.first?.url)
        #expect(requestURL == file.canonicalURL)
        #expect(!requestURL.absoluteString.contains("token="))
        #expect(requestURL.query() == "alt=media")
        #expect(authorizer.calls == [.init(url: file.canonicalURL, forceRefresh: false)])
    }

    @Test("Images are authorized and decoded the same way")
    func imageDownload() async throws {
        let file = StorageFile(folder: "imagess", fileExtension: "jpg")
        let (session, log) = StubURLProtocol.session(answering: file.canonicalURL, inOrder: [.response(statusCode: 200, body: Self.pngData())])
        let loader = makeLoader(session: session)

        let image = try await loader.image(from: file.url(token: "revoked-token"), maxPixelSize: 1000)

        #expect(image.size == CGSize(width: 8, height: 4))
        #expect(log.header("Authorization", at: 0) == "Firebase cached-token")
        #expect(log.header("X-Firebase-AppCheck", at: 0) == "app-check-token")
    }

    @Test("Large images are downsampled to the requested size")
    func imageIsDownsampled() async throws {
        let file = StorageFile(folder: "imagess", fileExtension: "jpg")
        let (session, _) = StubURLProtocol.session(answering: file.canonicalURL, inOrder: [.response(statusCode: 200, body: Self.pngData())])
        let loader = makeLoader(session: session)

        let image = try await loader.image(from: file.url(token: "t"), maxPixelSize: 4)

        #expect(max(image.size.width, image.size.height) == 4)
    }

    // MARK: - Network policy

    @Test("A speculative (prefetch) load restricts the request to unmetered networks")
    func speculativeLoadRestrictsNetwork() async throws {
        let file = StorageFile(folder: "imagess", fileExtension: "jpg")
        let (session, log) = StubURLProtocol.session(answering: file.canonicalURL, inOrder: [.response(statusCode: 200, body: Self.pngData())])
        let loader = makeLoader(session: session)

        _ = try await loader.image(from: file.canonicalURL, maxPixelSize: 1000, speculative: true)

        let request = try #require(log.requests.first)
        #expect(!request.allowsConstrainedNetworkAccess)
        #expect(!request.allowsExpensiveNetworkAccess)
    }

    @Test("A normal load (the page on screen) is allowed on any network")
    func normalLoadAllowsAnyNetwork() async throws {
        let file = StorageFile(folder: "imagess", fileExtension: "jpg")
        let (session, log) = StubURLProtocol.session(answering: file.canonicalURL, inOrder: [.response(statusCode: 200, body: Self.pngData())])
        let loader = makeLoader(session: session)

        _ = try await loader.image(from: file.canonicalURL, maxPixelSize: 1000)

        let request = try #require(log.requests.first)
        #expect(request.allowsConstrainedNetworkAccess)
        #expect(request.allowsExpensiveNetworkAccess)
    }

    // MARK: - Caching

    @Test("A file is stored once, as a local copy, not also in the response cache")
    func fileIsNotAlsoStoredInResponseCache() async throws {
        let file = StorageFile()
        let (session, log) = StubURLProtocol.session(answering: file.canonicalURL, inOrder: [.response(statusCode: 200, body: body)])
        let loader = makeLoader(session: session)

        let first = try await loader.localFile(from: file.url(token: "first"), fileName: "exam.pdf")
        #expect(try Data(contentsOf: first) == body)
        // No double store: the bytes live only in the local file, never also in the URL response cache.
        #expect(session.configuration.urlCache?.cachedResponse(for: URLRequest(url: file.canonicalURL)) == nil)

        // Opening the same file again is served from the local copy, without another download.
        let second = try await loader.localFile(from: file.url(token: "second"), fileName: "exam.pdf")
        #expect(second == first)
        #expect(log.count == 1)
        #expect(authorizer.calls.count == 1)
    }

    @Test("A downloaded file opens even when nobody is signed in any more")
    func cachedFileOpensWithoutSession() async throws {
        let file = StorageFile()
        let (session, log) = StubURLProtocol.session(answering: file.canonicalURL, inOrder: [.response(statusCode: 200, body: body)])
        let loader = makeLoader(session: session)
        _ = try await loader.localFile(from: file.url(token: "first"), fileName: "exam.pdf")
        authorizer.failure = ArchiveError.permissionDenied

        // The local copy serves the file offline; no credentials are needed once it is on disk.
        let second = try await loader.localFile(from: file.canonicalURL, fileName: "exam.pdf")

        #expect(try Data(contentsOf: second) == body)
        #expect(log.count == 1)
    }

    @Test("The local copy of a file does not depend on the token in its URL")
    func localCopyIsSharedAcrossTokens() async throws {
        let file = StorageFile()
        let (session, log) = StubURLProtocol.session(answering: file.canonicalURL, inOrder: [.response(statusCode: 200, body: body)])
        let loader = makeLoader(session: session)

        let first = try await loader.localFile(from: file.url(token: "first"), fileName: "exam.pdf")
        let second = try await loader.localFile(from: file.url(token: "second"), fileName: "exam.pdf")
        let withoutToken = try await loader.localFile(from: file.canonicalURL, fileName: "exam.pdf")

        #expect(first == second)
        #expect(first == withoutToken)
        #expect(log.count == 1)
        #expect(authorizer.calls.count == 1)
    }

    @Test("A decoded image is kept in memory per file, whatever its token")
    func imageMemoryCache() async throws {
        let file = StorageFile(folder: "imagess", fileExtension: "jpg")
        let (session, log) = StubURLProtocol.session(answering: file.canonicalURL, inOrder: [.response(statusCode: 200, body: Self.pngData())])
        let loader = makeLoader(session: session)

        let first = try await loader.image(from: file.url(token: "first"), maxPixelSize: 1000)
        let second = try await loader.image(from: file.url(token: "second"), maxPixelSize: 1000)

        #expect(first === second)
        #expect(log.count == 1)
        #expect(authorizer.calls.count == 1)
    }

    @Test("Bytes that cannot be decoded are not kept in the cache")
    func undecodableImageIsEvicted() async throws {
        let file = StorageFile(folder: "imagess", fileExtension: "jpg")
        let (session, log) = StubURLProtocol.session(answering: file.canonicalURL, inOrder: [.response(statusCode: 200, body: body)])
        let loader = makeLoader(session: session)

        await #expect(throws: ArchiveError.self) {
            try await loader.image(from: file.url(token: "t"), maxPixelSize: 1000)
        }
        #expect(session.configuration.urlCache?.cachedResponse(for: URLRequest(url: file.canonicalURL)) == nil)

        await #expect(throws: ArchiveError.self) {
            try await loader.image(from: file.url(token: "t"), maxPixelSize: 1000)
        }
        #expect(log.count == 2, "The broken response had to be downloaded again")
    }

    @Test("Concurrent requests for the same file share one download")
    func concurrentRequestsShareOneDownload() async throws {
        let file = StorageFile()
        let (session, log) = StubURLProtocol.session(answering: file.canonicalURL, inOrder: [.response(statusCode: 200, body: body)])
        let loader = makeLoader(session: session)
        let gate = AsyncGate()
        authorizer.gate = gate

        let first = Task { try await loader.localFile(from: file.url(token: "first"), fileName: "first.pdf") }
        await gate.waitForArrival()
        let second = Task { try await loader.localFile(from: file.url(token: "second"), fileName: "second.pdf") }
        await Task.yield()
        gate.open()
        let results = try await [first.value, second.value]

        #expect(try results.map { try Data(contentsOf: $0) } == [body, body])
        #expect(log.count == 1)
        #expect(authorizer.calls.count == 1)
    }

    // MARK: - Rejected requests

    @Test("A rejected token is refreshed once and the download is retried", arguments: [401, 403])
    func rejectedTokenIsRefreshed(statusCode: Int) async throws {
        let file = StorageFile()
        let (session, log) = StubURLProtocol.session(
            answering: file.canonicalURL,
            inOrder: [.response(statusCode: statusCode, body: Data()), .response(statusCode: 200, body: body)]
        )
        let loader = makeLoader(session: session)

        let local = try await loader.localFile(from: file.url(token: "t"), fileName: "exam.pdf")

        #expect(try Data(contentsOf: local) == body)
        #expect(authorizer.calls.map(\.forceRefresh) == [false, true])
        #expect(log.count == 2)
        #expect(log.header("Authorization", at: 0) == "Firebase cached-token")
        #expect(log.header("Authorization", at: 1) == "Firebase refreshed-token")
        #expect(log.header("X-Firebase-AppCheck", at: 1) == "app-check-token")
    }

    @Test("A token rejected twice means no access, and nothing is cached", arguments: [401, 403])
    func rejectedTwice(statusCode: Int) async throws {
        let file = StorageFile()
        let (session, log) = StubURLProtocol.session(answering: file.canonicalURL, inOrder: [.response(statusCode: statusCode, body: Data())])
        let loader = makeLoader(session: session)

        await #expect(throws: ArchiveError.permissionDenied) {
            try await loader.localFile(from: file.url(token: "t"), fileName: "exam.pdf")
        }

        #expect(authorizer.calls.map(\.forceRefresh) == [false, true])
        #expect(log.count == 2, "The download is retried once, not forever")
        #expect(session.configuration.urlCache?.cachedResponse(for: URLRequest(url: file.canonicalURL)) == nil)
    }

    @Test("Other error statuses are not retried and report the file as unavailable", arguments: [404, 429, 500, 503])
    func otherErrorStatus(statusCode: Int) async throws {
        let file = StorageFile()
        let (session, log) = StubURLProtocol.session(answering: file.canonicalURL, inOrder: [.response(statusCode: statusCode, body: Data())])
        let loader = makeLoader(session: session)

        await #expect(throws: ArchiveError.fileUnavailable(statusCode: statusCode)) {
            try await loader.localFile(from: file.url(token: "t"), fileName: "exam.pdf")
        }

        #expect(log.count == 1)
        #expect(authorizer.calls.count == 1)
        #expect(session.configuration.urlCache?.cachedResponse(for: URLRequest(url: file.canonicalURL)) == nil)
    }

    @Test("A file that failed to load is requested again, not remembered as failed")
    func failureIsNotSticky() async throws {
        let file = StorageFile()
        let (session, log) = StubURLProtocol.session(
            answering: file.canonicalURL,
            inOrder: [.response(statusCode: 503, body: Data()), .response(statusCode: 200, body: body)]
        )
        let loader = makeLoader(session: session)
        await #expect(throws: ArchiveError.fileUnavailable(statusCode: 503)) {
            try await loader.localFile(from: file.url(token: "t"), fileName: "exam.pdf")
        }

        let local = try await loader.localFile(from: file.url(token: "t"), fileName: "exam.pdf")

        #expect(try Data(contentsOf: local) == body)
        #expect(log.count == 2)
    }

    // MARK: - Without credentials

    @Test("Nobody signed in means no access, and no request is sent")
    func notSignedIn() async throws {
        let file = StorageFile()
        let (session, log) = StubURLProtocol.session(answering: file.canonicalURL, inOrder: [.response(statusCode: 200, body: body)])
        authorizer.failure = ArchiveError.permissionDenied
        let loader = makeLoader(session: session)

        await #expect(throws: ArchiveError.permissionDenied) {
            try await loader.localFile(from: file.url(token: "t"), fileName: "exam.pdf")
        }

        #expect(log.requests.isEmpty)
    }

    @Test("Without an authorizer Storage downloads are denied")
    func noAuthorizer() async throws {
        let file = StorageFile()
        let (session, log) = StubURLProtocol.session(answering: file.canonicalURL, inOrder: [.response(statusCode: 200, body: body)])
        let loader = RemoteFileLoader(session: session, cacheDirectory: cacheDirectory, authorizer: nil)

        await #expect(throws: ArchiveError.permissionDenied) {
            try await loader.localFile(from: file.url(token: "t"), fileName: "exam.pdf")
        }

        #expect(log.requests.isEmpty)
    }

    @Test("An ID token that cannot be fetched offline is reported as offline")
    func tokenFetchOffline() async throws {
        let file = StorageFile()
        let (session, log) = StubURLProtocol.session(answering: file.canonicalURL, inOrder: [.response(statusCode: 200, body: body)])
        authorizer.failure = ArchiveError.offline
        let loader = makeLoader(session: session)

        await #expect(throws: ArchiveError.offline) {
            try await loader.localFile(from: file.url(token: "t"), fileName: "exam.pdf")
        }

        #expect(log.requests.isEmpty)
    }

    @Test("A lost connection is reported as offline", arguments: [URLError.Code.notConnectedToInternet, .timedOut, .networkConnectionLost])
    func transportFailure(code: URLError.Code) async throws {
        let file = StorageFile()
        let (session, log) = StubURLProtocol.session(answering: file.canonicalURL, inOrder: [.failure(code)])
        let loader = makeLoader(session: session)

        await #expect(throws: ArchiveError.offline) {
            try await loader.localFile(from: file.url(token: "t"), fileName: "exam.pdf")
        }

        #expect(log.count == 1)
    }

    // MARK: - Files that need no credentials

    @Test("Local files are read directly, without credentials")
    func fileURLsBypassAuthorization() async throws {
        let source = cacheDirectory.appending(path: "sample.pdf")
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try body.write(to: source)
        let session = StubURLProtocol.session(answering: URL(filePath: "/unused"), with: .failure(.badURL))
        let loader = makeLoader(session: session)

        let local = try await loader.localFile(from: source, fileName: "sample.pdf")

        #expect(try Data(contentsOf: local) == body)
        #expect(authorizer.calls.isEmpty)
    }

    @Test("A missing local file is reported as not found")
    func missingLocalFile() async {
        let session = StubURLProtocol.session(answering: URL(filePath: "/unused"), with: .failure(.badURL))
        let loader = makeLoader(session: session)

        await #expect(throws: ArchiveError.notFound) {
            try await loader.localFile(from: URL(filePath: "/exams/\(UUID().uuidString).pdf"), fileName: "missing.pdf")
        }

        #expect(authorizer.calls.isEmpty)
    }

    @Test("Files on other hosts are fetched plainly: no credentials leave the app")
    func otherHostsGetNoCredentials() async throws {
        let url = try #require(URL(string: "https://example.com/\(UUID().uuidString).pdf?token=abc"))
        let (session, log) = StubURLProtocol.session(answering: url, inOrder: [.response(statusCode: 200, body: body)])
        let loader = makeLoader(session: session)

        let local = try await loader.localFile(from: url, fileName: "exam.pdf")

        #expect(try Data(contentsOf: local) == body)
        #expect(log.count == 1)
        #expect(log.header("Authorization", at: 0) == nil)
        #expect(log.header("X-Firebase-AppCheck", at: 0) == nil)
        #expect(authorizer.calls.isEmpty)
    }

    // MARK: - Helpers

    private func makeLoader(session: URLSession) -> RemoteFileLoader {
        RemoteFileLoader(session: session, cacheDirectory: cacheDirectory, authorizer: authorizer)
    }

    /// A small PNG (8 x 4 pixels).
    private static func pngData() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 4), format: format)
        return renderer.pngData { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        }
    }
}

/// A file of the bucket, under a name nobody else uses.
private struct StorageFile {
    let canonicalURL: URL
    private let path: String

    init(folder: String = "pdfs", fileExtension: String = "pdf") {
        path = "https://firebasestorage.googleapis.com/v0/b/vifi-831a8.appspot.com/o/\(folder)%2F\(UUID().uuidString).\(fileExtension)"
        canonicalURL = URL(string: "\(path)?alt=media") ?? URL(filePath: "/invalid")
    }

    /// The stored download URL, with `token` as its (soon revoked) download token.
    func url(token: String) -> URL {
        URL(string: "\(path)?alt=media&token=\(token)") ?? URL(filePath: "/invalid")
    }
}

// MARK: - Maintenance (release & purge)

@Suite("RemoteFileLoader maintenance", .timeLimit(.minutes(1)))
final class RemoteFileLoaderMaintenanceTests {
    private let authorizer = StubRequestAuthorizer()
    private let cacheDirectory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    private let body = Data("exam file contents".utf8)

    deinit {
        try? FileManager.default.removeItem(at: cacheDirectory)
    }

    @Test("Releasing a decoded image re-decodes it without downloading again")
    func releaseImageDropsTheDecodedCopy() async throws {
        let file = StorageFile(folder: "imagess", fileExtension: "jpg")
        let (session, log) = StubURLProtocol.session(answering: file.canonicalURL, inOrder: [.response(statusCode: 200, body: Self.pngData())])
        let loader = makeLoader(session: session)
        let first = try await loader.image(from: file.canonicalURL, maxPixelSize: 1000)

        loader.releaseImage(from: file.canonicalURL, maxPixelSize: 1000)
        let second = try await loader.image(from: file.canonicalURL, maxPixelSize: 1000)

        #expect(first !== second, "The decoded image was dropped, so it is decoded afresh")
        #expect(log.count == 1, "The response bytes are still cached; no new download")
    }

    @Test("Purging deletes the local file so it is downloaded again")
    func purgeDeletesLocalFiles() async throws {
        let file = StorageFile()
        let (session, log) = StubURLProtocol.session(
            answering: file.canonicalURL,
            inOrder: [.response(statusCode: 200, body: body), .response(statusCode: 200, body: body)]
        )
        let loader = makeLoader(session: session)
        let local = try await loader.localFile(from: file.canonicalURL, fileName: "exam.pdf")
        #expect(FileManager.default.fileExists(atPath: local.path(percentEncoded: false)))

        await loader.purge()

        #expect(!FileManager.default.fileExists(atPath: local.path(percentEncoded: false)))
        _ = try await loader.localFile(from: file.canonicalURL, fileName: "exam.pdf")
        #expect(log.count == 2, "After a purge the file is downloaded again, not served from a leftover copy")
    }

    @Test("A purge during a download leaves no file behind")
    func purgeDuringDownloadWritesNothing() async throws {
        let file = StorageFile()
        let (session, _) = StubURLProtocol.session(answering: file.canonicalURL, inOrder: [.response(statusCode: 200, body: body)])
        let loader = makeLoader(session: session)
        let gate = AsyncGate()
        authorizer.gate = gate
        let task = Task { try await loader.localFile(from: file.canonicalURL, fileName: "exam.pdf") }
        await gate.waitForArrival()

        await loader.purge()
        gate.open()

        await #expect(throws: (any Error).self) {
            try await task.value
        }
        // The download that finished mid-purge must not resurrect a file for the deleted account.
        let filesDirectory = cacheDirectory.appending(path: "Files", directoryHint: .isDirectory)
        #expect(RemoteFileLoader.directorySize(of: filesDirectory, fileManager: .default) == 0)
    }

    @Test("Purging drops cached responses and decoded images")
    func purgeClearsImageCaches() async throws {
        let file = StorageFile(folder: "imagess", fileExtension: "jpg")
        let (session, log) = StubURLProtocol.session(
            answering: file.canonicalURL,
            inOrder: [.response(statusCode: 200, body: Self.pngData()), .response(statusCode: 200, body: Self.pngData())]
        )
        let loader = makeLoader(session: session)
        _ = try await loader.image(from: file.canonicalURL, maxPixelSize: 1000)
        #expect(session.configuration.urlCache?.cachedResponse(for: URLRequest(url: file.canonicalURL)) != nil)

        await loader.purge()

        #expect(session.configuration.urlCache?.cachedResponse(for: URLRequest(url: file.canonicalURL)) == nil)
        _ = try await loader.image(from: file.canonicalURL, maxPixelSize: 1000)
        #expect(log.count == 2, "The decoded image and the response were dropped, so the bytes are fetched again")
    }

    // MARK: - Helpers

    private func makeLoader(session: URLSession) -> RemoteFileLoader {
        RemoteFileLoader(session: session, cacheDirectory: cacheDirectory, authorizer: authorizer)
    }

    /// A small PNG (8 x 4 pixels).
    private static func pngData() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 4), format: format)
        return renderer.pngData { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
        }
    }
}

// MARK: - Disk pruning

@Suite("RemoteFileLoader disk pruning")
final class RemoteFileLoaderPruningTests {
    private let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test("The oldest files are deleted first, until the total is within budget")
    func prunesOldestFirst() async throws {
        try writeFolder("f0", modified: date(0))
        try writeFolder("f1", modified: date(1))
        try writeFolder("f2", modified: date(2))
        let oneSize = RemoteFileLoader.directorySize(of: folder("f0"), fileManager: .default)

        await RemoteFileLoader.pruneFiles(in: directory, budget: 2 * oneSize, keepNewerThan: 0)

        #expect(try remainingFolders() == ["f1", "f2"])
    }

    @Test("Nothing is deleted when the total is within budget")
    func keepsEverythingUnderBudget() async throws {
        try writeFolder("f0", modified: date(0))
        try writeFolder("f1", modified: date(1))
        let oneSize = RemoteFileLoader.directorySize(of: folder("f0"), fileManager: .default)

        await RemoteFileLoader.pruneFiles(in: directory, budget: 10 * oneSize, keepNewerThan: 0)

        #expect(try remainingFolders() == ["f0", "f1"])
    }

    @Test("A recently touched file is never pruned, even over budget")
    func protectsRecentFiles() async throws {
        try writeFolder("recent", modified: Date())
        try writeFolder("old1", modified: date(0))
        try writeFolder("old2", modified: date(1))

        await RemoteFileLoader.pruneFiles(in: directory, budget: 0, keepNewerThan: 3600)

        #expect(try remainingFolders() == ["recent"], "Only the file touched within the window survives")
    }

    @Test("Pruning a missing directory does nothing")
    func missingDirectory() async {
        await RemoteFileLoader.pruneFiles(in: directory, budget: 0, keepNewerThan: 0)
        #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
    }

    // MARK: - Helpers

    private func folder(_ name: String) -> URL {
        directory.appending(path: name, directoryHint: .isDirectory)
    }

    /// Writes a 64 KB file in `directory/<name>/file.bin`, then stamps the folder's modification date.
    private func writeFolder(_ name: String, modified: Date) throws {
        let folderURL = folder(name)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Data(count: 64 * 1024).write(to: folderURL.appending(path: "file.bin"))
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: folderURL.path(percentEncoded: false))
    }

    private func remainingFolders() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)).sorted()
    }

    private func date(_ offset: TimeInterval) -> Date {
        Date(timeIntervalSinceReferenceDate: offset)
    }
}

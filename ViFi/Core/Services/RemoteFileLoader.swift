import CryptoKit
import Foundation
import ImageIO
import os
import UIKit

/// Downloads exam files once and serves them from memory and disk afterwards, so an exam that has been
/// opened keeps working offline.
///
/// - Responses live in a dedicated on-disk `URLCache` and are answered from it whenever present.
/// - Images are decoded and downsampled off the main actor, then kept in memory per URL and size.
/// - Files handed out for PDF rendering and sharing are written under a per-URL folder, with a readable name.
/// - Concurrent requests for the same URL share a single download.
///
/// Firebase Storage files are downloaded with the signed-in user's credentials (see `RequestAuthorizing`)
/// and identified by their canonical URL, without the `token=` query parameter of the stored download URLs:
/// tokens are being revoked, and a URL with another token still names the same file. Local `file://` URLs
/// (sample data) are read directly.
final class RemoteFileLoader: RemoteFileLoading {
    private static let memoryCacheCapacity = 64 * 1024 * 1024
    private static let diskCacheCapacity = 512 * 1024 * 1024
    private static let decodedImageCostLimit = 128 * 1024 * 1024

    private let session: URLSession
    /// The session's response cache, read and written explicitly under each file's canonical URL.
    private let responseCache: URLCache?
    private let authorizer: (any RequestAuthorizing)?
    private let filesDirectory: URL
    private let images = NSCache<NSString, UIImage>()
    private var downloads: [URL: Task<Data, any Error>] = [:]

    /// - Parameters:
    ///   - session: The session to download with. `nil` creates one backed by a large on-disk cache that
    ///     prefers cached responses over the network (`.returnCacheDataElseLoad`).
    ///   - cacheDirectory: Root folder of the on-disk caches. `nil` uses `Caches/ExamFiles`.
    ///   - authorizer: Adds the user's credentials to Firebase Storage downloads. Without one, such downloads
    ///     fail with `ArchiveError.permissionDenied`.
    init(session: URLSession? = nil, cacheDirectory: URL? = nil, authorizer: (any RequestAuthorizing)? = nil) {
        let directory = cacheDirectory ?? URL.cachesDirectory.appending(path: "ExamFiles", directoryHint: .isDirectory)
        let responsesDirectory = directory.appending(path: "Responses", directoryHint: .isDirectory)
        let session = session ?? Self.makeSession(cacheDirectory: responsesDirectory)
        self.session = session
        responseCache = session.configuration.urlCache
        self.authorizer = authorizer
        filesDirectory = directory.appending(path: "Files", directoryHint: .isDirectory)
        images.totalCostLimit = Self.decodedImageCostLimit
    }

    func image(from url: URL, maxPixelSize: CGFloat) async throws -> UIImage {
        let url = Self.canonicalURL(for: url)
        let key = Self.imageCacheKey(for: url, maxPixelSize: maxPixelSize)
        if let cached = images.object(forKey: key) {
            return cached
        }

        let data = try await data(from: url)
        try Task.checkCancellation()

        let decoded: DecodedImage
        do {
            decoded = try await Self.decodeImage(from: data, maxPixelSize: maxPixelSize)
        } catch {
            // Bytes that cannot be decoded must not keep being served from the cache.
            evictCachedResponse(for: url)
            Logger.files.error("Decoding image \(url, privacy: .private) failed")
            throw error
        }
        images.setObject(decoded.image, forKey: key, cost: decoded.cost)
        return decoded.image
    }

    func localFile(from url: URL, fileName: String) async throws -> URL {
        let url = Self.canonicalURL(for: url)
        let destination = Self.localFileURL(for: url, fileName: fileName, in: filesDirectory)
        if await Self.fileExists(at: destination) {
            return destination
        }
        let data = try await data(from: url)
        try await Self.write(data, to: destination)
        return destination
    }
}

// MARK: - Downloading

private extension RemoteFileLoader {
    /// The file's bytes, joining an in-flight download of the same (canonical) URL when there is one.
    ///
    /// Downloads are not cancelled when a caller goes away: finishing them warms the cache for the
    /// next request (scrolling back, opening the viewer, sharing).
    func data(from url: URL) async throws -> Data {
        if let download = downloads[url] {
            return try await download.value
        }

        let download = Task { [session, responseCache, authorizer] in
            try await Self.download(url, session: session, cache: responseCache, authorizer: authorizer)
        }
        downloads[url] = download
        defer { downloads[url] = nil }

        do {
            return try await download.value
        } catch {
            if let archiveError = error as? ArchiveError, case .fileUnavailable = archiveError {
                // An error response must not stick in the cache once the file is back.
                evictCachedResponse(for: url)
            }
            if !(error is CancellationError) {
                let reason = String(describing: error)
                Logger.files.error("Loading \(url, privacy: .private) failed: \(reason, privacy: .public)")
            }
            throw error
        }
    }

    func evictCachedResponse(for url: URL) {
        responseCache?.removeCachedResponse(for: Self.cacheKey(for: url))
    }

    static func makeSession(cacheDirectory: URL) -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(
            memoryCapacity: memoryCacheCapacity,
            diskCapacity: diskCacheCapacity,
            directory: cacheDirectory
        )
        // Exam files never change behind a download URL, so a cached copy is always good enough.
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }

    /// Reads a local file, or downloads a remote one: Firebase Storage files with the user's credentials
    /// (answered from the response cache first), anything else as a plain request.
    static func download(
        _ url: URL,
        session: URLSession,
        cache: URLCache?,
        authorizer: (any RequestAuthorizing)?
    ) async throws -> Data {
        if url.isFileURL {
            return try await readLocalFile(at: url)
        }
        guard isFirebaseStorageURL(url) else {
            return try await fetch(URLRequest(url: url), using: session, cache: nil)
        }
        if let cache, let cached = await cachedData(for: url, in: cache) {
            return cached
        }
        guard let authorizer else { throw ArchiveError.permissionDenied }

        do {
            let request = try await authorizer.authorizedRequest(for: url, forceRefresh: false)
            return try await fetch(request, using: session, cache: cache)
        } catch let error as ArchiveError where error.isAuthorizationFailure {
            // An expired or revoked ID token: retry once with a fresh one.
            Logger.files.info("Download of \(url, privacy: .private) was rejected; retrying with a fresh token")
        }
        do {
            let request = try await authorizer.authorizedRequest(for: url, forceRefresh: true)
            return try await fetch(request, using: session, cache: cache)
        } catch let error as ArchiveError where error.isAuthorizationFailure {
            throw ArchiveError.permissionDenied
        }
    }

    /// Sends `request` and returns the body of a 2xx response, storing that response in `cache` under the
    /// request's (credential-free) URL.
    @concurrent
    nonisolated static func fetch(_ request: URLRequest, using session: URLSession, cache: URLCache?) async throws -> Data {
        var request = request
        if cache != nil {
            // The cache was consulted under the canonical key already; responses are stored explicitly below
            // rather than relying on automatic caching of requests with an `Authorization` header.
            request.cachePolicy = .reloadIgnoringLocalCacheData
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw mapped(error)
        }

        if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            throw ArchiveError.fileUnavailable(statusCode: response.statusCode)
        }
        if let cache, let url = request.url {
            cache.storeCachedResponse(CachedURLResponse(response: response, data: data), for: cacheKey(for: url))
        }
        return data
    }

    @concurrent
    nonisolated static func readLocalFile(at url: URL) async throws -> Data {
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ArchiveError.notFound
        }
    }

    /// The body of a cached successful response for `url`; disk access, so off the main actor.
    @concurrent
    nonisolated static func cachedData(for url: URL, in cache: URLCache) async -> Data? {
        guard let cached = cache.cachedResponse(for: cacheKey(for: url)) else { return nil }
        if let response = cached.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            return nil
        }
        return cached.data
    }

    /// Translates transport errors into the errors the UI knows how to present.
    nonisolated static func mapped(_ error: any Error) -> any Error {
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .cancelled:
            return CancellationError()
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
             .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .callIsActive:
            return ArchiveError.offline
        default:
            return ArchiveError.unknown(message: urlError.localizedDescription)
        }
    }
}

// MARK: - Canonical URLs

extension RemoteFileLoader {
    /// The host of Firebase Storage download URLs.
    nonisolated static let firebaseStorageHost = "firebasestorage.googleapis.com"

    nonisolated static func isFirebaseStorageURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host()?.lowercased() == firebaseStorageHost
    }

    /// `url` without its `token` query item when it is a Firebase Storage download URL (`alt=media` and
    /// any other item are kept, encoded as they were); any other URL is returned unchanged.
    ///
    /// The canonical URL is the file's identity everywhere: in-flight downloads, the memory and response
    /// caches and the local file folders. It is also the URL that is requested, with the user's credentials.
    nonisolated static func canonicalURL(for url: URL) -> URL {
        guard isFirebaseStorageURL(url),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.percentEncodedQueryItems else {
            return url
        }
        let kept = items.filter { $0.name != "token" }
        guard kept.count != items.count else { return url }
        components.percentEncodedQueryItems = kept.isEmpty ? nil : kept
        return components.url ?? url
    }

    /// The header-less request a response is cached under.
    nonisolated static func cacheKey(for url: URL) -> URLRequest {
        URLRequest(url: url)
    }
}

private extension ArchiveError {
    /// Firebase Storage answers 401 for a missing or invalid token and 403 when rules deny the read.
    nonisolated var isAuthorizationFailure: Bool {
        if case let .fileUnavailable(statusCode) = self {
            return statusCode == 401 || statusCode == 403
        }
        return false
    }
}

// MARK: - Images

private extension RemoteFileLoader {
    nonisolated struct DecodedImage: Sendable {
        let image: UIImage
        /// Bytes held by the decoded bitmap, used as the memory cache cost.
        let cost: Int
    }

    static func imageCacheKey(for url: URL, maxPixelSize: CGFloat) -> NSString {
        let size = maxPixelSize.isFinite ? Int(maxPixelSize.rounded(.up)) : 0
        return "\(url.absoluteString)#\(size)" as NSString
    }

    /// Decodes straight to a bitmap no larger than `maxPixelSize` on its longest side, honouring the
    /// EXIF orientation, without ever materialising the full-size image.
    @concurrent
    nonisolated static func decodeImage(from data: Data, maxPixelSize: CGFloat) async throws -> DecodedImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0 else {
            throw undecodableImageError
        }

        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if maxPixelSize.isFinite, maxPixelSize >= 1 {
            options[kCGImageSourceThumbnailMaxPixelSize] = Int(maxPixelSize.rounded(.up))
        }

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw undecodableImageError
        }
        return DecodedImage(image: UIImage(cgImage: cgImage), cost: cgImage.bytesPerRow * cgImage.height)
    }

    nonisolated static var undecodableImageError: ArchiveError {
        .unknown(message: String(localized: "Sayfa görüntüsü açılamadı. Lütfen daha sonra tekrar dene."))
    }
}

// MARK: - Local files

private extension RemoteFileLoader {
    /// `<directory>/<sha256 of the URL>/<sanitized file name>`: one folder per source file, so equal names
    /// from different exams never collide while the shared file keeps a readable name.
    nonisolated static func localFileURL(for url: URL, fileName: String, in directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let folderName = digest.map { String(format: "%02x", $0) }.joined()
        return directory
            .appending(path: folderName, directoryHint: .isDirectory)
            .appending(path: sanitizedFileName(fileName), directoryHint: .notDirectory)
    }

    /// A single path component that is safe on disk and still recognisable when shared.
    nonisolated static func sanitizedFileName(_ fileName: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters).union(.newlines)
        let cleaned = fileName
            .components(separatedBy: forbidden)
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        guard !cleaned.isEmpty else {
            return String(localized: "Dosya")
        }

        // Stay well below the 255-byte file name limit, keeping the extension intact.
        let maxBaseLength = 100
        let fileExtension = (cleaned as NSString).pathExtension
        let baseName = (cleaned as NSString).deletingPathExtension
        guard baseName.count > maxBaseLength else { return cleaned }
        let truncated = String(baseName.prefix(maxBaseLength)).trimmingCharacters(in: .whitespaces)
        return fileExtension.isEmpty ? truncated : "\(truncated).\(fileExtension)"
    }

    @concurrent
    nonisolated static func fileExists(at url: URL) async -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    @concurrent
    nonisolated static func write(_ data: Data, to url: URL) async throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        } catch {
            let message = String(localized: "Dosya cihaza kaydedilemedi. Boş alanını kontrol edip tekrar dene.")
            throw ArchiveError.unknown(message: message)
        }
    }
}

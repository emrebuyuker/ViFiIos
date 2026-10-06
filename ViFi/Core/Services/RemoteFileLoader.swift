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
final class RemoteFileLoader: RemoteFileLoading {
    private static let memoryCacheCapacity = 64 * 1024 * 1024
    private static let diskCacheCapacity = 512 * 1024 * 1024
    private static let decodedImageCostLimit = 128 * 1024 * 1024

    private let session: URLSession
    private let filesDirectory: URL
    private let images = NSCache<NSString, UIImage>()
    private var downloads: [URL: Task<Data, any Error>] = [:]

    /// - Parameters:
    ///   - session: The session to download with. `nil` creates one backed by a large on-disk cache that
    ///     prefers cached responses over the network (`.returnCacheDataElseLoad`).
    ///   - cacheDirectory: Root folder of the on-disk caches. `nil` uses `Caches/ExamFiles`.
    init(session: URLSession? = nil, cacheDirectory: URL? = nil) {
        let directory = cacheDirectory ?? URL.cachesDirectory.appending(path: "ExamFiles", directoryHint: .isDirectory)
        let responsesDirectory = directory.appending(path: "Responses", directoryHint: .isDirectory)
        self.session = session ?? Self.makeSession(cacheDirectory: responsesDirectory)
        filesDirectory = directory.appending(path: "Files", directoryHint: .isDirectory)
        images.totalCostLimit = Self.decodedImageCostLimit
    }

    func image(from url: URL, maxPixelSize: CGFloat) async throws -> UIImage {
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
    /// The file's bytes, joining an in-flight download of the same URL when there is one.
    ///
    /// Downloads are not cancelled when a caller goes away: finishing them warms the cache for the
    /// next request (scrolling back, opening the viewer, sharing).
    func data(from url: URL) async throws -> Data {
        if let download = downloads[url] {
            return try await download.value
        }

        let download = Task { [session] in
            try await Self.fetch(url, using: session)
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
        session.configuration.urlCache?.removeCachedResponse(for: URLRequest(url: url))
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

    @concurrent
    nonisolated static func fetch(_ url: URL, using session: URLSession) async throws -> Data {
        if url.isFileURL {
            do {
                return try Data(contentsOf: url, options: .mappedIfSafe)
            } catch {
                throw ArchiveError.notFound
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw mapped(error)
        }

        if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            throw ArchiveError.fileUnavailable(statusCode: response.statusCode)
        }
        return data
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

import Foundation
import UIKit

/// Reads the exam archive.
protocol ArchiveRepository: AnyObject {
    /// Entries listed under `path` (universities at the root), sorted for display.
    func items(at path: ArchivePath) async throws -> [ArchiveItem]

    /// The files of the exam at `path` (a depth-5 path).
    func document(at path: ArchivePath) async throws -> ExamDocument

    /// Emits whenever the archive changes, including when fresh server data replaces the copy cached
    /// by a previous session. Lists re-read their entries on each element; the stream ends when the
    /// consuming task is cancelled.
    func archiveChanges() -> AsyncStream<Void>
}

extension ArchiveRepository {
    /// Sources without live updates (sample data, test doubles) never change.
    func archiveChanges() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

/// Downloads exam files with an on-disk cache.
protocol RemoteFileLoading: AnyObject {
    /// A decoded image, downsampled so its longest side is at most `maxPixelSize` pixels.
    func image(from url: URL, maxPixelSize: CGFloat) async throws -> UIImage

    /// A local copy of the file (cached), named `fileName`; used for PDFs and sharing.
    func localFile(from url: URL, fileName: String) async throws -> URL
}

/// Adds the signed-in user's credentials to downloads of protected exam files.
protocol RequestAuthorizing: AnyObject {
    /// A request for `url` carrying the user's ID token and, when available, an App Check token.
    ///
    /// - Parameter forceRefresh: Fetches a fresh ID token instead of the cached one, after the server
    ///   rejected a request.
    /// - Throws: `ArchiveError.permissionDenied` when nobody is signed in, `ArchiveError.offline` when the
    ///   token cannot be refreshed for lack of a connection.
    func authorizedRequest(for url: URL, forceRefresh: Bool) async throws -> URLRequest
}

/// A newer App Store release than the installed version.
nonisolated struct AppUpdate: Equatable, Sendable {
    let version: String
    let storeURL: URL
}

protocol AppUpdateChecking: AnyObject {
    /// `nil` when the app is up to date or the check fails.
    func availableUpdate() async -> AppUpdate?
}

nonisolated enum AnalyticsEvent: Equatable, Sendable {
    case screenView(name: String)
    case browse(level: ArchiveLevel)
    case examOpened(kind: ExamKind)
    case examShared(kind: ExamKind)
    case recentExamOpened
}

protocol AnalyticsTracking: AnyObject {
    func track(_ event: AnalyticsEvent)
}

/// Errors surfaced to the user by the data layer.
nonisolated enum ArchiveError: LocalizedError, Equatable {
    /// The node does not exist or has no files.
    case notFound
    /// Database rules rejected the read.
    case permissionDenied
    /// No connection or a timeout.
    case offline
    /// The file host refused the download (e.g. an HTTP 4xx/5xx status).
    case fileUnavailable(statusCode: Int)
    case unknown(message: String)

    var errorDescription: String? {
        switch self {
        case .notFound:
            String(localized: "İçerik bulunamadı.")
        case .permissionDenied:
            String(localized: "Bu içeriğe şu anda erişilemiyor.")
        case .offline:
            String(localized: "İnternet bağlantısı yok. Bağlantını kontrol edip tekrar dene.")
        case .fileUnavailable:
            String(localized: "Dosya şu anda sunucudan alınamıyor. Lütfen daha sonra tekrar dene.")
        case let .unknown(message):
            message
        }
    }
}

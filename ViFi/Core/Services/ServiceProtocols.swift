import Foundation
import UIKit

/// Reads the exam archive.
protocol ArchiveRepository: AnyObject {
    /// Entries listed under `path` (universities at the root), sorted for display.
    func items(at path: ArchivePath) async throws -> [ArchiveItem]

    /// The files of the exam at `path` (a depth-5 path).
    func document(at path: ArchivePath) async throws -> ExamDocument

    /// Warms the source's offline cache with the whole archive, so later reads work without a connection.
    /// Best-effort, called off the critical path: callers ignore failures and retry. A requirement (not only
    /// an extension member) so a call through `any ArchiveRepository` dispatches to the concrete source.
    func prefetchArchive() async throws

    /// Emits whenever the archive changes, including when fresh server data replaces the copy cached
    /// by a previous session. Lists re-read their entries on each element; the stream ends when the
    /// consuming task is cancelled.
    func archiveChanges() -> AsyncStream<Void>
}

extension ArchiveRepository {
    /// Sources that keep themselves available offline (the Realtime Database via `keepSynced`) or have nothing
    /// remote to warm (sample data, test doubles) do nothing.
    func prefetchArchive() async throws {}

    /// Sources without live updates (sample data, test doubles) never change.
    func archiveChanges() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

/// Downloads exam files with an on-disk cache.
protocol RemoteFileLoading: AnyObject {
    /// A decoded image, downsampled so its longest side is at most `maxPixelSize` pixels.
    ///
    /// - Parameter speculative: When `true`, this is a prefetch of a page the user is not looking at; it is
    ///   restricted to unmetered networks and fails fast on cellular / Low Data Mode (callers ignore that
    ///   failure). The page the user is actually viewing is always loaded with `speculative: false`.
    func image(from url: URL, maxPixelSize: CGFloat, speculative: Bool) async throws -> UIImage

    /// Drops the in-memory decoded image for `url` at `maxPixelSize`, so a closed viewer stops holding a
    /// large full-screen bitmap. The on-disk copy stays, so re-opening it needs no new download.
    func releaseImage(from url: URL, maxPixelSize: CGFloat)

    /// A local copy of the file (cached), named `fileName`; used for PDFs and sharing.
    func localFile(from url: URL, fileName: String) async throws -> URL

    /// Trims the on-disk file cache back within its budget, oldest first. Safe to call at launch and when the
    /// app goes to the background.
    func pruneDiskCache() async

    /// Removes every downloaded file, cached response and decoded image. Used when the account is deleted.
    func purge() async
}

extension RemoteFileLoading {
    /// Loads the page the user is looking at (non-speculative), on any network.
    func image(from url: URL, maxPixelSize: CGFloat) async throws -> UIImage {
        try await image(from: url, maxPixelSize: maxPixelSize, speculative: false)
    }
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

/// A release the user can move to, and where to get it.
nonisolated struct AppUpdate: Equatable, Sendable {
    let version: String
    let storeURL: URL
    /// A message from the remote config, shown instead of the default copy; `nil` uses the default.
    let message: String?
}

/// The update requirement for the installed version.
nonisolated enum AppUpdateStatus: Equatable, Sendable {
    /// Up to date, or the policy could not be read.
    case upToDate
    /// A newer version exists; the user may keep using the app (a dismissible prompt).
    case optional(AppUpdate)
    /// The installed version is below the required minimum; the app is blocked until it updates.
    case required(AppUpdate)
}

protocol AppUpdateChecking: AnyObject {
    /// A live stream of the update requirement: the current status, then again whenever the remote policy
    /// changes. A required update stays latched when the policy later becomes unreadable, so the app is
    /// never silently un-gated. The stream ends when the consuming task is cancelled.
    func statusChanges() -> AsyncStream<AppUpdateStatus>
}

nonisolated enum AnalyticsEvent: Equatable, Sendable {
    case screenView(name: String)
    case browse(level: ArchiveLevel)
    case examOpened(kind: ExamKind)
    case recentExamOpened

    // Coin economy
    case examUnlockSheetShown(canAfford: Bool)
    case earnCoinsTapped
    case examUnlocked(kind: ExamKind, coinsSpent: Int, alreadyUnlocked: Bool)
    case examUnlockFailed(reason: String)

    // Exam submission (supply side)
    case examSubmitted(kind: ExamKind, fileCount: Int, tier: SubmissionTier?)
    case examSubmitFailed(reason: String)

    // Login funnel
    case loginCodeRequested(isResend: Bool)
    case loginSucceeded
    /// `step` is the `LoginFailureStage` raw value ("send_code" | "verify"); `reason` is `AuthError.analyticsReason`.
    case loginFailed(reason: String, step: String)

    // Activation
    case onboardingCompleted(method: String, source: String)
    case profileCompleted
    case profileUpdated
    case searchUsed(level: ArchiveLevel, zeroResults: Bool)

    // Lifecycle & operations
    case signedOut
    case accountDeleted
    case updatePromptShown(isRequired: Bool)
    case updateAction(action: String)
    case submissionApproved(tier: SubmissionTier)
    case submissionRejected

    // Notification permission (step 1/2) and campaign consent (step 2/2); `source` is prompt | reask | settings.
    case notificationPrimingShown(source: NotificationPromptSource)
    case notificationPrimingAccepted(source: NotificationPromptSource)
    case notificationPrimingDeclined(source: NotificationPromptSource)
    case marketingConsentShown(source: NotificationPromptSource)
    case marketingConsentAccepted(source: NotificationPromptSource)
    case marketingConsentDeclined(source: NotificationPromptSource)
}

/// The signed-in user's analytics identity: a stable id plus low-cardinality, canonical segment
/// properties (never free text or anything identifying). `nil` clears the identity on sign-out.
nonisolated struct AnalyticsUser: Equatable, Sendable {
    let id: String
    let universityId: String?
    let facultyId: String?
    let departmentId: String?
    /// "female" | "male".
    let gender: String?
    let isAdmin: Bool

    /// Builds the identity from the user's id, their profile (when present) and admin status.
    init(id: String, profile: UserProfile?, isAdmin: Bool) {
        self.id = id
        universityId = profile?.universityId
        facultyId = profile?.facultyId
        departmentId = profile?.departmentId
        gender = profile?.gender.rawValue
        self.isAdmin = isAdmin
    }

    /// Every analytics user-property name, so each can be set or cleared on identity changes.
    static let propertyNames = ["university_id", "faculty_id", "department_id", "gender", "is_admin"]

    /// The user-property values that are known, keyed by name, clamped to Analytics' 36-character limit.
    /// A name absent from the map has no known value (e.g. no profile yet) and is cleared when applied.
    var properties: [String: String] {
        var result = ["is_admin": isAdmin ? "true" : "false"]
        result["university_id"] = Self.clamped(universityId)
        result["faculty_id"] = Self.clamped(facultyId)
        result["department_id"] = Self.clamped(departmentId)
        result["gender"] = Self.clamped(gender)
        return result
    }

    private static func clamped(_ value: String?) -> String? {
        value.map { String($0.prefix(36)) }
    }
}

protocol AnalyticsTracking: AnyObject {
    func track(_ event: AnalyticsEvent)
    /// Identifies the signed-in user (id + segment properties), or clears the identity with `nil`.
    func setUser(_ user: AnalyticsUser?)
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

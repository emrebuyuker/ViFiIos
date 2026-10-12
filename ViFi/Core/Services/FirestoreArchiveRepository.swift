@preconcurrency import FirebaseFirestore
import Foundation
import os

/// Reads the exam archive from Cloud Firestore.
///
/// A level is one query: catalog nodes by `parentId` (universities by `rootParentId`), or a course's exams by
/// `courseId`, both filtered to `status == published`. Documents are parsed by the Firestore-free
/// `FirestoreArchiveParser`, so the parsing is unit-tested with plain dictionaries.
///
/// Reading is gated by the security rules to signed-in +90 phone users and admins. Offline is served from
/// Firestore's own on-disk cache (`ViFiFirestore`), so there is no `keepSynced` equivalent and no live
/// whole-archive listener: `archiveChanges()` is intentionally passive (see `FIRESTORE-MIGRATION.md`).
///
/// Not wired into `AppEnvironment.live()` yet (the app still reads the Realtime Database); the switch happens
/// at the cutover (migration item #11), after the data has been migrated.
final class FirestoreArchiveRepository: ArchiveRepository {
    private static let catalogCollection = "catalogNodes"
    private static let examsCollection = "exams"

    private let firestore: Firestore
    /// The Storage bucket used to build file URLs from the stored `storagePath`s.
    private let bucket: String

    init(firestore: Firestore = ViFiFirestore.shared, bucket: String) {
        self.firestore = firestore
        self.bucket = bucket
    }

    func items(at path: ArchivePath) async throws -> [ArchiveItem] {
        guard let childLevel = path.childLevel else { return [] }
        let docs = try await (childLevel == .exam ? examDocuments(forCourse: path) : catalogDocuments(under: path))
        return FirestoreArchiveParser.items(from: docs, under: path)
    }

    func document(at path: ArchivePath) async throws -> ExamDocument {
        guard let examID = path.components.last else { throw ArchiveError.notFound }
        let snapshot: DocumentSnapshot
        do {
            snapshot = try await firestore.collection(Self.examsCollection).document(examID).getDocument()
        } catch {
            throw Self.archiveError(from: error, at: path)
        }
        guard let data = snapshot.data() else {
            // Offline with persistence, `getDocument` returns a non-existent snapshot from the cache instead of
            // throwing. A cache-only miss is "not downloaded yet", not a deletion: surface it as offline so a
            // recents entry is not wrongly pruned (see `ExamDocumentViewModel`'s `.notFound` handling). A
            // server-confirmed miss stays `.notFound`.
            throw snapshot.metadata.isFromCache ? ArchiveError.offline : ArchiveError.notFound
        }
        guard let document = FirestoreArchiveParser.document(from: data, at: path, bucket: bucket) else {
            throw ArchiveError.notFound
        }
        return document
    }

    /// Warms the on-disk cache with the whole published archive, so an offline list query for a branch the user
    /// has not visited is served from the cache instead of coming back empty (Firestore has no `keepSynced`, so
    /// only visited queries would otherwise be cached). Each collection is read `from: .server`: the fetch both
    /// refreshes the cache and, when offline, throws — so the caller skips rather than recording a cache-only
    /// read as a completed warm. The results are discarded; their documents stay in the cache for later reads.
    func prefetchArchive() async throws {
        try await prefetchPublished(in: Self.catalogCollection)
        try await prefetchPublished(in: Self.examsCollection)
    }

    /// Intentionally passive: Firestore has no cheap whole-archive change signal (the server version node was
    /// deliberately not added — see `FIRESTORE-MIGRATION.md`/T6). Lists refresh on appearance and pull-to-refresh;
    /// offline is served from Firestore's on-disk cache.
    func archiveChanges() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

// MARK: - Queries

private extension FirestoreArchiveRepository {
    typealias Row = (id: String, data: [String: Any])

    func catalogDocuments(under path: ArchivePath) async throws -> [Row] {
        let parentID = path.isRoot ? FirestoreArchiveParser.rootParentId : (path.components.last ?? "")
        let query = firestore.collection(Self.catalogCollection)
            .whereField(FirestoreArchiveParser.Field.parentId, isEqualTo: parentID)
            .whereField(FirestoreArchiveParser.Field.status, isEqualTo: FirestoreArchiveParser.publishedStatus)
        return try await rows(from: query, at: path)
    }

    func examDocuments(forCourse path: ArchivePath) async throws -> [Row] {
        guard let courseID = path.components.last else { return [] }
        let query = firestore.collection(Self.examsCollection)
            .whereField(FirestoreArchiveParser.Field.courseId, isEqualTo: courseID)
            .whereField(FirestoreArchiveParser.Field.status, isEqualTo: FirestoreArchiveParser.publishedStatus)
        return try await rows(from: query, at: path)
    }

    func rows(from query: Query, at path: ArchivePath) async throws -> [Row] {
        do {
            let snapshot = try await query.getDocuments()
            return snapshot.documents.map { ($0.documentID, $0.data()) }
        } catch {
            throw Self.archiveError(from: error, at: path)
        }
    }

    /// Fetches every published document of `collection` from the server, so they are cached for offline reads.
    /// A single-field equality query, served by the automatic index. The snapshot is discarded (only its
    /// caching side effect matters); the raw error propagates for the caller to log and retry.
    func prefetchPublished(in collection: String) async throws {
        _ = try await firestore.collection(collection)
            .whereField(FirestoreArchiveParser.Field.status, isEqualTo: FirestoreArchiveParser.publishedStatus)
            .getDocuments(source: .server)
    }

    /// Maps a Firestore error to a user-facing `ArchiveError`; anything unexpected is logged.
    nonisolated static func archiveError(from error: any Error, at path: ArchivePath) -> ArchiveError {
        let nsError = error as NSError
        if nsError.domain == FirestoreErrorDomain, let code = FirestoreErrorCode.Code(rawValue: nsError.code) {
            switch code {
            case .permissionDenied:
                return .permissionDenied
            case .unavailable, .deadlineExceeded:
                return .offline
            case .notFound:
                return .notFound
            default:
                break
            }
        }
        let location = path.components.joined(separator: "/")
        let reason = String(describing: error)
        Logger.archive.error("Firestore read of \(location, privacy: .public) failed: \(reason, privacy: .public)")
        return .unknown(message: error.localizedDescription)
    }
}

@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseFunctions
@preconcurrency import FirebaseStorage
import Foundation
import os

/// Calls the admin notification Cloud Functions (`getNotificationAudience`, `previewNotification`,
/// `sendNotification`, `cancelNotification`; `europe-west1`, admin claim required), uploads campaign images to Cloud
/// Storage (`notificationImages/<id>.jpg`, admin create-only) and reads the `notifications` history from the named
/// `vifi` Firestore database (NOTIFICATIONS.md §3.1, §4, §6).
///
/// Callable results and history documents are turned into models by the Firebase-free `NotificationPayloadParser`;
/// a malformed answer is reported as an unknown error rather than guessed at.
final class FirebaseNotificationAdminService: NotificationAdminServicing {
    private static let region = "europe-west1"
    private static let notificationsCollection = "notifications"
    private static let historyLimit = 50
    /// Document fields the parser reads as dates; Firestore hands them over as `Timestamp`.
    private nonisolated static let dateFields = ["createdAt", "sentAt", "scheduledAt", "expiresAt"]

    private let functions: Functions
    private let storage: Storage

    init(functions: Functions = Functions.functions(region: region), storage: Storage = ViFiStorage.shared) {
        self.functions = functions
        self.storage = storage
    }

    func audience() async throws -> AudienceFacets {
        let data = try await call("getNotificationAudience", with: nil)
        guard let facets = NotificationPayloadParser.facets(from: data) else { throw Self.unexpectedResponse }
        return facets
    }

    func preview(kind: NotificationKind, audience: NotificationAudience) async throws -> NotificationPreview {
        // The wire shape of an audience lives with the draft's payload; reuse it instead of copying it.
        var draft = NotificationDraft()
        draft.audience = audience
        let data = try await call("previewNotification", with: ["kind": kind.rawValue, "audience": draft.payload["audience"] ?? [:]])
        guard let preview = NotificationPayloadParser.preview(from: data) else { throw Self.unexpectedResponse }
        return preview
    }

    func uploadImage(_ jpeg: Data, notificationId: String) async throws -> String {
        guard !jpeg.isEmpty, jpeg.count <= NotificationImage.maxBytes,
              NotificationPayloadParser.isValidNotificationId(notificationId) else {
            throw NotificationAdminError.imageUploadFailed
        }
        let path = NotificationImage.storagePath(forNotificationId: notificationId)
        let reference = storage.reference(withPath: path)
        // A retried send finds its image already there: the rules forbid overwriting it, so it is reused as is.
        do {
            _ = try await reference.getMetadata()
            return path
        } catch {
            guard Self.isObjectNotFound(error) else { throw Self.imageError(from: error) }
        }
        // Only the content type: the server checks it (and the size) before sending.
        let metadata = StorageMetadata()
        metadata.contentType = "image/jpeg"
        do {
            _ = try await reference.putDataAsync(jpeg, metadata: metadata)
            return path
        } catch {
            throw Self.imageError(from: error)
        }
    }

    func send(_ draft: NotificationDraft) async throws -> NotificationSendResult {
        let data = try await call("sendNotification", with: draft.payload)
        guard let result = NotificationPayloadParser.sendResult(from: data) else { throw Self.unexpectedResponse }
        return result
    }

    func cancel(notificationId: String) async throws {
        _ = try await call("cancelNotification", with: ["notificationId": notificationId], isCancellation: true)
    }

    func history() async throws -> [SentNotification] {
        do {
            let snapshot = try await ViFiFirestore.shared.collection(Self.notificationsCollection)
                .order(by: "createdAt", descending: true)
                .limit(to: Self.historyLimit)
                .getDocuments()
            return snapshot.documents.compactMap { document in
                NotificationPayloadParser.sentNotification(id: document.documentID, data: Self.readingDates(document.data()))
            }
        } catch {
            throw Self.adminError(from: error)
        }
    }

    // MARK: - Calls

    private static let unexpectedResponse = NotificationAdminError.unknown(
        message: String(localized: "Sunucudan beklenmeyen bir yanıt alındı.")
    )

    private func call(_ name: String, with data: sending Any?, isCancellation: Bool = false) async throws -> Any {
        do {
            return try await functions.httpsCallable(name).call(data).data
        } catch {
            throw Self.adminError(from: error, isCancellation: isCancellation)
        }
    }

    // MARK: - Mapping

    /// Maps a Functions, Firestore or transport error to a `NotificationAdminError`, logging the original when it
    /// is not one the admin can act on. The server's Turkish message travels with `.invalidDraft`.
    ///
    /// - Parameter isCancellation: A failed precondition on `cancelNotification` means the notification already
    ///   went out (or was canceled), which has its own error.
    nonisolated static func adminError(from error: any Error, isCancellation: Bool = false) -> NotificationAdminError {
        let nsError = error as NSError
        if nsError.domain == FunctionsErrorDomain, let code = FunctionsErrorCode(rawValue: nsError.code) {
            switch code {
            case .permissionDenied, .unauthenticated:
                return .permissionDenied
            case .failedPrecondition where isCancellation:
                return .notCancelable
            case .invalidArgument, .failedPrecondition:
                return .invalidDraft(message: nsError.localizedDescription)
            case .unavailable, .deadlineExceeded:
                return .offline
            default:
                break
            }
        } else if nsError.domain == FirestoreErrorDomain, let code = FirestoreErrorCode.Code(rawValue: nsError.code) {
            switch code {
            case .permissionDenied, .unauthenticated:
                return .permissionDenied
            case .unavailable, .deadlineExceeded:
                return .offline
            default:
                break
            }
        } else if nsError.domain == NSURLErrorDomain {
            return .offline
        }
        Logger.app.error("Notification admin call failed: \(String(describing: error), privacy: .public)")
        return .unknown(message: error.localizedDescription)
    }

    /// Whether a Storage call failed because the object does not exist (yet).
    nonisolated static func isObjectNotFound(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == StorageErrorDomain && nsError.code == StorageErrorCode.objectNotFound.rawValue
    }

    /// Maps a failed image upload: no permission and no connection as usual, anything else as an upload failure.
    nonisolated static func imageError(from error: any Error) -> NotificationAdminError {
        let nsError = error as NSError
        if nsError.domain == StorageErrorDomain, let code = StorageErrorCode(rawValue: nsError.code) {
            switch code {
            case .unauthorized, .unauthenticated:
                return .permissionDenied
            case .retryLimitExceeded:
                return .offline
            default:
                break
            }
        } else if nsError.domain == NSURLErrorDomain {
            return .offline
        }
        Logger.app.error("Notification image upload failed: \(String(describing: error), privacy: .public)")
        return .imageUploadFailed
    }

    /// Replaces the date fields' Firestore `Timestamp`s with `Date`s, which is what the parser reads. Private to
    /// this file on purpose: the inbox reader has its own copy, so the two never share (and conflict on) a helper.
    private nonisolated static func readingDates(_ data: [String: Any]) -> [String: Any] {
        var data = data
        for field in dateFields {
            if let timestamp = data[field] as? Timestamp {
                data[field] = timestamp.dateValue()
            }
        }
        return data
    }
}

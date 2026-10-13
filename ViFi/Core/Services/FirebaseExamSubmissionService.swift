@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseStorage
import Foundation
import os

/// Creates a pending exam submission in Cloud Firestore (`submissions/<id>`, named `vifi` database) after
/// uploading its files to Cloud Storage (`pending/<uid>/<submissionId>/…`).
///
/// A submission requires a signed-in +90 user; the rules reject everything else. Files are uploaded first,
/// then the document is written with the stable `storagePath`s and a server timestamp — so the moderation
/// Cloud Function (which bypasses the rules) can copy the owner's files on approval. If any step fails, the
/// already-uploaded files are removed on a best-effort basis so no orphans are left behind.
final class FirebaseExamSubmissionService: ExamSubmissionServicing {
    private static let collection = "submissions"

    private let auth: any AuthServicing
    private let firestore: Firestore
    private let storage: Storage

    init(
        auth: any AuthServicing,
        firestore: Firestore = ViFiFirestore.shared,
        storage: Storage = ViFiStorage.shared
    ) {
        self.auth = auth
        self.firestore = firestore
        self.storage = storage
    }

    func submit(_ submission: ExamSubmission, ownerId: String) async throws {
        // The owner must be the signed-in user; the rules enforce this too, but failing early avoids uploads.
        guard auth.currentUser?.id == ownerId else { throw ExamSubmissionError.notSignedIn }
        guard submission.isValid else { throw ExamSubmissionError.invalidSubmission }

        let document = firestore.collection(Self.collection).document()
        let payload = ExamSubmissionPayload.make(from: submission, ownerId: ownerId, submissionId: document.documentID)

        var uploaded: [String] = []
        do {
            for file in payload.files {
                try await upload(file)
                uploaded.append(file.storagePath)
            }
            var fields = payload.firestoreFields
            fields["createdAt"] = FieldValue.serverTimestamp()
            try await document.setData(fields)
        } catch {
            await cleanUp(uploaded)
            Self.log(error)
            throw Self.submissionError(from: error)
        }
    }

    /// Uploads one file to its storage path with only the content type set — the Storage rules reject any
    /// custom metadata, served filename or content encoding.
    private func upload(_ file: UploadFile) async throws {
        let metadata = StorageMetadata()
        metadata.contentType = file.contentType
        _ = try await storage.reference(withPath: file.storagePath).putDataAsync(file.data, metadata: metadata)
    }

    /// Removes already-uploaded files after a later step failed. Best-effort: delete errors are ignored.
    private func cleanUp(_ storagePaths: [String]) async {
        for path in storagePaths {
            _ = try? await storage.reference(withPath: path).delete()
        }
    }
}

// MARK: - Encoding & error mapping

extension FirebaseExamSubmissionService {
    /// Maps a Firestore or Storage error to an `ExamSubmissionError`.
    nonisolated static func submissionError(from error: any Error) -> ExamSubmissionError {
        if let error = error as? ExamSubmissionError { return error }
        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain { return .offline }

        if nsError.domain == FirestoreErrorDomain, let code = FirestoreErrorCode.Code(rawValue: nsError.code) {
            switch code {
            case .permissionDenied: return .permissionDenied
            case .unavailable, .deadlineExceeded: return .offline
            default: break
            }
        }

        if nsError.domain == StorageErrorDomain, let code = StorageErrorCode(rawValue: nsError.code) {
            switch code {
            case .unauthorized, .unauthenticated: return .permissionDenied
            case .retryLimitExceeded: return .offline
            default: break
            }
        }

        return .unknown(message: genericMessage)
    }

    private nonisolated static var genericMessage: String {
        String(localized: "Gönderimin kaydedilemedi. Lütfen tekrar dene.")
    }

    private nonisolated static func log(_ error: any Error) {
        guard !(error is CancellationError) else { return }
        let reason = String(describing: error)
        Logger.app.error("Exam submission failed: \(reason, privacy: .public)")
    }
}

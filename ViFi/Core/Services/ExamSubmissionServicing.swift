import Foundation

/// Submits a user-contributed exam for moderation: uploads its files to Cloud Storage and creates the pending
/// Firestore `submissions/<id>` document.
///
/// The live implementation requires a signed-in +90 user; the database and storage rules reject every other
/// request. Every throwing operation throws `ExamSubmissionError` (or `CancellationError`).
protocol ExamSubmissionServicing: AnyObject {
    /// Uploads the submission's files and creates the pending submission owned by `ownerId`. On success the
    /// files live under `pending/<ownerId>/<submissionId>/…` and the document is written with `status:
    /// "pending"`; the server (Admin SDK) handles moderation and any coin reward afterwards.
    func submit(_ submission: ExamSubmission, ownerId: String) async throws
}

/// Exam-submission errors, with messages shown to the user.
nonisolated enum ExamSubmissionError: LocalizedError, Equatable {
    /// Nobody is signed in, or the owner does not match the signed-in user.
    case notSignedIn
    /// The submission does not satisfy the required invariants (should be caught by the form first).
    case invalidSubmission
    /// Database or storage rules rejected the request.
    case permissionDenied
    /// No connection or a timeout.
    case offline
    case unknown(message: String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            String(localized: "Oturumun sona erdi. Lütfen yeniden giriş yap.")
        case .invalidSubmission:
            String(localized: "Gönderimin eksik veya geçersiz. Lütfen bilgileri kontrol et.")
        case .permissionDenied:
            String(localized: "Gönderimin şu anda kaydedilemiyor. Lütfen daha sonra tekrar dene.")
        case .offline:
            String(localized: "İnternet bağlantısı yok. Bağlantını kontrol edip tekrar dene.")
        case let .unknown(message):
            message
        }
    }
}

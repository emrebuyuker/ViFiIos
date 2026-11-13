import Foundation

/// The result of approving a submission: the tier it was judged at, the coins granted, and the id of the exam
/// it will publish or, for a duplicate submission (K22), the existing exam it will replace at the second approval.
/// Nothing is published yet.
nonisolated struct ApprovalResult: Equatable, Sendable {
    let tier: SubmissionTier
    let coins: Int
    let publishedExamId: String?
}

/// Admin-only moderation of user submissions: list the queue, approve (publish + credit) or reject.
///
/// Serverless: an admin's device performs the writes, gated by the `isAdmin()` security rules. Approving is
/// idempotent — the ledger entry is keyed by the submission id and the submission must still be `pending`.
protocol ModerationServicing: AnyObject {
    /// The submissions awaiting review, newest first.
    func pendingSubmissions() async throws -> [ExamSubmissionRecord]

    /// First approval (4.2.0): copies the files into the public archive storage, credits the owner the tier
    /// reward and marks the submission `approved` with the chosen AI `provider` and the `publishPlan`. It writes
    /// no catalog nodes or exams; the server converts the pages into draft questions and the admin publishes
    /// them at the second approval.
    func approve(_ record: ExamSubmissionRecord, provider: AIProvider) async throws -> ApprovalResult

    /// The id of the existing archive exam this submission duplicates, or `nil` when it is new (or the archive could
    /// not be resolved). Drives the "already in the archive" warning on the detail screen.
    func duplicateExamId(of record: ExamSubmissionRecord) async -> String?

    /// Rejects a submission, with an optional reason recorded on it.
    func reject(_ record: ExamSubmissionRecord, reason: String?) async throws

    /// Deletes a published exam from the archive: removes its `exams` document, decrements its course's child
    /// count, and best-effort deletes the Storage files. `path` is the exam's archive path (…/course/exam).
    func deleteExam(at path: ArchivePath) async throws
}

/// Moderation failures, with Turkish messages for the admin UI.
nonisolated enum ModerationError: LocalizedError, Equatable {
    /// The submission is no longer pending (already approved or rejected, perhaps by another admin).
    case notPending
    /// The reward was already credited for this submission.
    case alreadyCredited
    case offline
    case permissionDenied
    case unknown(message: String)

    var errorDescription: String? {
        switch self {
        case .notPending:
            String(localized: "Bu gönderim artık beklemede değil; listeyi yenile.")
        case .alreadyCredited:
            String(localized: "Bu gönderim için ödül zaten verilmiş.")
        case .offline:
            String(localized: "İnternet bağlantısı yok. Bağlantını kontrol edip tekrar dene.")
        case .permissionDenied:
            String(localized: "Bu işlem için yetkin yok.")
        case let .unknown(message):
            message
        }
    }
}

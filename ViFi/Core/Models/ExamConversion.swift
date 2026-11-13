import Foundation

// An AI conversion job (admin only): one exam's pages → draft questions → admin review → publish. The read side of
// `examConversions/<jobId>` in `firebase/functions/conversions/schema.js`; keep the statuses and fields in sync.

nonisolated enum ConversionStatus: String, CaseIterable, Codable, Sendable {
    case queued
    case processing
    case ready
    case failed
    case published
    case discarded

    /// `published` and `discarded` never change again.
    var isTerminal: Bool { self == .published || self == .discarded }
}

/// Where the job's files came from: an archive exam converted by an admin, or an approved user submission.
nonisolated enum ConversionSource: Hashable, Sendable {
    case legacy(examId: String)
    case submission(submissionId: String)

    /// The job's document id: `exam-<examId>` / `sub-<submissionId>` (as `conversionJobId` on the server).
    var jobId: String {
        switch self {
        case let .legacy(examId): "exam-\(examId)"
        case let .submission(submissionId): "sub-\(submissionId)"
        }
    }
}

/// Token and cost accounting of a job (the $50 monthly cap is summed server-side).
nonisolated struct ConversionUsage: Hashable, Sendable {
    let inputTokens: Int
    let outputTokens: Int
    let costUsd: Double
}

nonisolated struct ExamConversion: Identifiable, Hashable, Sendable {
    let id: String
    let source: ConversionSource
    let kind: ExamKind
    let status: ConversionStatus
    /// The provider the admin picked for the latest run.
    let provider: AIProvider?
    let attempts: Int
    /// Last failure, shown on the failed-jobs list.
    let error: String?
    let usage: ConversionUsage?
    /// Display names for the review screen ("BOZOK › … › 2019 FİNAL"); empty when unknown.
    let placementNames: [String]
    let createdAt: Date?
    let readyAt: Date?
    /// The exam's original pages (`files [{storagePath, order}]` of the job), for the side-by-side review.
    var files: [SubmissionFileRef] = []
    /// The server's suggested country-wide course identity (`placement.subjectId` / `subjectName`), if it has one.
    var suggestedSubjectId: String?
    var suggestedSubjectName: String?
}

import Foundation

// Service contracts of the 4.2.0 structured exams. Faz 0 defines them so the parallel Faz 1 tracks (1C user screen,
// 1D admin) build against the same shapes; the Firestore / Cloud Functions implementations arrive in Faz 1 and are
// wired into `AppEnvironment` then. Debug sample: `MockStructuredExamServices.swift`; test doubles:
// `ViFiTests/StructuredExamTestDoubles.swift`.

/// Reads the published questions of an exam (`questions where examId == X order by order`, ~10–30 reads).
protocol ExamQuestionReading: AnyObject {
    /// The exam's questions in reading order; empty when it has none.
    func questions(examId: String) async throws -> [ExamQuestion]
}

/// Admin-only AI conversion workflow. Every action that runs a model takes the provider the admin picked (K9);
/// there is no server-side default. Calls go to admin-gated callables, so they fail for non-admins.
protocol ExamConversionServicing: AnyObject {
    /// Jobs in the given statuses (e.g. `[.ready]` for the review list, `[.failed]` for retries), newest first.
    func conversions(statuses: Set<ConversionStatus>) async throws -> [ExamConversion]

    /// The draft questions of a job, in order.
    func draftQuestions(jobId: String) async throws -> [ExamQuestion]

    /// Queues a legacy archive exam for conversion ("Yeni yapıya geçir"); returns the job (an existing active job is
    /// returned unchanged).
    func requestConversion(examId: String, provider: AIProvider) async throws -> ExamConversion

    /// Regenerates the whole exam (a second-approval rejection, K14) or retries a failed job.
    func regenerate(jobId: String, provider: AIProvider) async throws

    /// Regenerates a single draft question (K8).
    func regenerateQuestion(jobId: String, order: Int, provider: AIProvider) async throws

    /// Saves an admin's edit of a draft question's text, choices, answer or solution (K8).
    func saveDraftQuestion(jobId: String, question: ExamQuestion) async throws

    /// Second approval: publishes the draft into `questions` and marks the exam `format: structured`.
    func publish(jobId: String) async throws

    /// "Sınavı iptal et" (K14): gives the job up for good (`discarded`); coins are never taken back.
    func discard(jobId: String) async throws
}

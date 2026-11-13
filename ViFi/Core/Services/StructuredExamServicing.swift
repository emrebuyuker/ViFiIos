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

    /// Second approval: publishes the draft into `questions` and marks the exam `format: structured`. `subjectId`
    /// picks an existing country-wide course identity, `newSubjectName` opens a new one; both `nil` lets the server
    /// use its own suggestion.
    @discardableResult
    func publish(jobId: String, subjectId: String?, newSubjectName: String?) async throws -> PublishedExamResult

    /// "Sınavı iptal et" (K14): gives the job up for good (`discarded`); coins are never taken back.
    func discard(jobId: String) async throws

    /// Bulk conversion (K12b) of a course's or department's unconverted exams. With `dryRun` nothing is queued and
    /// the estimate (exam count, cost) comes back for the admin's confirmation.
    func requestBulkConversion(scope: BulkConversionScope, provider: AIProvider, dryRun: Bool) async throws -> BulkConversionEstimate

    /// This month's AI spend (`aiUsage/<YYYY-MM>`), for the $50 gauge; zero when nothing was spent yet.
    func monthlyUsage() async throws -> AIMonthlyUsage

    /// K15: edits a published question's text, speech, choices, answer or solution; it goes live at once and the
    /// id does not change.
    func updatePublishedQuestion(_ question: ExamQuestion) async throws

    /// K15: regenerates one published question with the picked provider.
    func regeneratePublishedQuestion(questionId: String, provider: AIProvider) async throws
}

/// The conversion workflow where none is wired (an `AppEnvironment` built without one): every call fails, so an
/// admin screen shows an error instead of silently doing nothing.
final class UnavailableExamConversionService: ExamConversionServicing {
    private let failure = ExamConversionError.unknown(message: String(localized: "Dönüştürme servisi kullanılamıyor."))

    func conversions(statuses: Set<ConversionStatus>) async throws -> [ExamConversion] { throw failure }
    func draftQuestions(jobId: String) async throws -> [ExamQuestion] { throw failure }
    func requestConversion(examId: String, provider: AIProvider) async throws -> ExamConversion { throw failure }
    func regenerate(jobId: String, provider: AIProvider) async throws { throw failure }
    func regenerateQuestion(jobId: String, order: Int, provider: AIProvider) async throws { throw failure }
    func saveDraftQuestion(jobId: String, question: ExamQuestion) async throws { throw failure }
    func publish(jobId: String, subjectId: String?, newSubjectName: String?) async throws -> PublishedExamResult { throw failure }
    func discard(jobId: String) async throws { throw failure }
    func requestBulkConversion(scope: BulkConversionScope, provider: AIProvider, dryRun: Bool) async throws -> BulkConversionEstimate {
        throw failure
    }
    func monthlyUsage() async throws -> AIMonthlyUsage { throw failure }
    func updatePublishedQuestion(_ question: ExamQuestion) async throws { throw failure }
    func regeneratePublishedQuestion(questionId: String, provider: AIProvider) async throws { throw failure }
}

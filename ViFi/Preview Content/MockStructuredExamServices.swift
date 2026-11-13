#if DEBUG
import Foundation
import OSLog

/// Sample structured questions for previews, UI tests and demos (`-ViFiMockData`): read from the bundled
/// `sample-questions.json` through the real `ExamQuestionParser`, so the mock exercises the same parsing as the live
/// reader. Any exam id returns the sample set (re-labelled with that id); a missing file yields no questions.
final class MockExamQuestionReader: ExamQuestionReading {
    private let latency: Duration

    init(latency: Duration = .milliseconds(200)) {
        self.latency = latency
    }

    func questions(examId: String) async throws -> [ExamQuestion] {
        try await Task.sleep(for: latency)
        return Self.sampleQuestions(examId: examId)
    }

    /// The bundled sample questions, parsed. Shared with the mock conversion service's drafts.
    static func sampleQuestions(examId: String) -> [ExamQuestion] {
        guard let url = Bundle.main.url(forResource: "sample-questions", withExtension: "json")
            ?? Bundle.main.url(forResource: "sample-questions", withExtension: "json", subdirectory: "SampleExams"),
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let docs = root["questions"] as? [[String: Any]] else {
            Logger.archive.error("Mock sample-questions.json is missing or malformed; serving no questions")
            return []
        }
        let entries = docs.map { doc -> (id: String, data: [String: Any]) in
            var fields = doc
            fields["examId"] = examId
            let order = doc["order"] as? Int ?? 0
            return (id: "\(examId)-\(String(format: "%03d", order))", data: fields)
        }
        return ExamQuestionParser.questions(from: entries, examId: examId)
    }
}

/// An in-memory conversion workflow: one ready job and one failed job; actions update the jobs like the server would.
final class MockExamConversionService: ExamConversionServicing {
    private var jobs: [ExamConversion]
    private var usage = AIMonthlyUsage(month: AIMonthlyUsage.monthKey(for: .now), costUsd: 12.4)
    private let latency: Duration
    private var regenerationLeases: [String: Date] = [:]

    private static func leaseKey(_ jobId: String, _ order: Int) -> String { "\(jobId)#\(order)" }

    init(jobs: [ExamConversion] = MockExamConversionService.samples, latency: Duration = .milliseconds(300)) {
        self.jobs = jobs
        self.latency = latency
    }

    static let samples: [ExamConversion] = [
        ExamConversion(
            id: "sub-sub-1", source: .submission(submissionId: "sub-1"), kind: .images, status: .ready,
            provider: .claude, attempts: 1, error: nil,
            usage: ConversionUsage(inputTokens: 21_000, outputTokens: 6_500, costUsd: 0.42),
            placementNames: ["Boğaziçi Üniversitesi", "Mühendislik Fakültesi", "Bilgisayar Mühendisliği", "Ayrık Matematik", "2023 VİZE"],
            createdAt: Date(timeIntervalSince1970: 1_762_000_000), readyAt: Date(timeIntervalSince1970: 1_762_000_300),
            files: [
                SubmissionFileRef(storagePath: "imagess/mock-1.jpg", order: 1),
                SubmissionFileRef(storagePath: "imagess/mock-2.jpg", order: 2),
            ],
            suggestedSubjectId: "ayrik-matematik", suggestedSubjectName: "Ayrık Matematik"
        ),
        ExamConversion(
            id: "exam-mock-legacy", source: .legacy(examId: "mock-legacy"), kind: .pdf, status: .failed,
            provider: .gemini, attempts: 3, error: "Sayfalar okunamadı",
            usage: nil, placementNames: ["Sakarya Üniversitesi", "İşletme Fakültesi", "İşletme", "Muhasebe", "2022 FİNAL"],
            createdAt: Date(timeIntervalSince1970: 1_761_900_000), readyAt: nil
        ),
    ]

    func conversions(statuses: Set<ConversionStatus>) async throws -> [ExamConversion] {
        try await Task.sleep(for: latency)
        return jobs.filter { statuses.contains($0.status) }
    }

    func draftQuestions(jobId: String) async throws -> [ExamQuestion] {
        try await Task.sleep(for: latency)
        return MockExamQuestionReader.sampleQuestions(examId: jobId).map { question in
            var question = question
            question.regeneratingUntil = regenerationLeases[Self.leaseKey(jobId, question.order)]
            return question
        }
    }

    func requestConversion(examId: String, provider: AIProvider) async throws -> ExamConversion {
        try await Task.sleep(for: latency)
        let source = ConversionSource.legacy(examId: examId)
        if let active = jobs.first(where: { $0.id == source.jobId && !$0.status.isTerminal }) {
            return active
        }
        let job = ExamConversion(
            id: source.jobId, source: source, kind: .images, status: .queued, provider: provider, attempts: 0,
            error: nil, usage: nil, placementNames: [], createdAt: .now, readyAt: nil
        )
        jobs.removeAll { $0.id == job.id }
        jobs.insert(job, at: 0)
        return job
    }

    func regenerate(jobId: String, provider: AIProvider) async throws {
        try await Task.sleep(for: latency)
        update(jobId) { $0.with(status: .queued, provider: provider) }
    }

    func regenerateQuestion(jobId: String, order: Int, provider: AIProvider) async throws {
        try await Task.sleep(for: latency)
        // Like the server's lease: the draft shows as regenerating for a few seconds.
        regenerationLeases[Self.leaseKey(jobId, order)] = Date().addingTimeInterval(6)
    }

    func saveDraftQuestion(jobId: String, question: ExamQuestion) async throws {
        try await Task.sleep(for: latency)
    }

    func publish(jobId: String, subjectId: String?, newSubjectName: String?) async throws -> PublishedExamResult {
        try await Task.sleep(for: latency)
        update(jobId) { $0.with(status: .published) }
        return PublishedExamResult(examId: "mock-\(jobId)", questionCount: Self.sampleQuestionCount)
    }

    func discard(jobId: String) async throws {
        try await Task.sleep(for: latency)
        update(jobId) { $0.with(status: .discarded) }
    }

    func requestBulkConversion(scope: BulkConversionScope, provider: AIProvider, dryRun: Bool) async throws -> BulkConversionEstimate {
        try await Task.sleep(for: latency)
        let count = 12
        let cost = Double(count) * (provider == .claude ? 0.42 : 0.18)
        if !dryRun { usage = AIMonthlyUsage(month: usage.month, costUsd: usage.costUsd + cost) }
        return BulkConversionEstimate(examCount: count, estimatedCostUsd: cost, jobIds: dryRun ? [] : (1...count).map { "exam-bulk-\($0)" })
    }

    func monthlyUsage() async throws -> AIMonthlyUsage {
        try await Task.sleep(for: latency)
        return usage
    }

    func updatePublishedQuestion(_ question: ExamQuestion) async throws {
        try await Task.sleep(for: latency)
    }

    func regeneratePublishedQuestion(questionId: String, provider: AIProvider) async throws {
        try await Task.sleep(for: latency)
    }

    private static var sampleQuestionCount: Int { MockExamQuestionReader.sampleQuestions(examId: "count").count }

    private func update(_ jobId: String, _ change: (ExamConversion) -> ExamConversion) {
        guard let index = jobs.firstIndex(where: { $0.id == jobId }) else { return }
        jobs[index] = change(jobs[index])
    }
}

private extension ExamConversion {
    func with(status: ConversionStatus, provider: AIProvider? = nil) -> ExamConversion {
        ExamConversion(
            id: id, source: source, kind: kind, status: status, provider: provider ?? self.provider,
            attempts: attempts, error: status == .failed ? error : nil, usage: usage,
            placementNames: placementNames, createdAt: createdAt, readyAt: readyAt, files: files,
            suggestedSubjectId: suggestedSubjectId, suggestedSubjectName: suggestedSubjectName
        )
    }
}
#endif

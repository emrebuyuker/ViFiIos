import Foundation
@testable import ViFi

// Test doubles for the 4.2.0 structured-exam services (Faz 0 skeleton; Faz 1 tests extend them).

/// An `ExamQuestionReading` that serves scripted questions per exam and records which exams were read.
final class StubExamQuestionReader: ExamQuestionReading {
    var questionsByExam: [String: [ExamQuestion]] = [:]
    var error: (any Error)?
    /// When set, every call waits at the gate before it is answered.
    var gate: AsyncGate?
    private(set) var requestedExamIds: [String] = []

    func questions(examId: String) async throws -> [ExamQuestion] {
        requestedExamIds.append(examId)
        await gate?.pass()
        if let error { throw error }
        return questionsByExam[examId] ?? []
    }
}

/// An `ExamConversionServicing` that serves scripted jobs/drafts and records every action with its provider.
final class StubExamConversionService: ExamConversionServicing {
    enum Call: Equatable {
        case requestConversion(examId: String, provider: AIProvider)
        case regenerate(jobId: String, provider: AIProvider)
        case regenerateQuestion(jobId: String, order: Int, provider: AIProvider)
        case saveDraftQuestion(jobId: String, questionId: String)
        case publish(jobId: String, subjectId: String?, newSubjectName: String?)
        case discard(jobId: String)
        case requestBulk(scope: BulkConversionScope, provider: AIProvider, dryRun: Bool)
        case updatePublishedQuestion(questionId: String)
        case regeneratePublishedQuestion(questionId: String, provider: AIProvider)
    }

    var jobs: [ExamConversion] = []
    var bulkEstimate = BulkConversionEstimate(examCount: 0, estimatedCostUsd: 0, jobIds: [])
    var usage = AIMonthlyUsage(month: "2026-11", costUsd: 0)
    var publishResult = PublishedExamResult(examId: "exam-1", questionCount: 2)
    var draftsByJob: [String: [ExamQuestion]] = [:]
    var error: (any Error)?
    var gate: AsyncGate?
    private(set) var calls: [Call] = []

    func conversions(statuses: Set<ConversionStatus>) async throws -> [ExamConversion] {
        await gate?.pass()
        if let error { throw error }
        return jobs.filter { statuses.contains($0.status) }
    }

    func draftQuestions(jobId: String) async throws -> [ExamQuestion] {
        await gate?.pass()
        if let error { throw error }
        return draftsByJob[jobId] ?? []
    }

    func requestConversion(examId: String, provider: AIProvider) async throws -> ExamConversion {
        try await record(.requestConversion(examId: examId, provider: provider))
        let source = ConversionSource.legacy(examId: examId)
        return ExamConversion(
            id: source.jobId, source: source, kind: .images, status: .queued, provider: provider, attempts: 0,
            error: nil, usage: nil, placementNames: [], createdAt: nil, readyAt: nil
        )
    }

    func regenerate(jobId: String, provider: AIProvider) async throws {
        try await record(.regenerate(jobId: jobId, provider: provider))
    }

    func regenerateQuestion(jobId: String, order: Int, provider: AIProvider) async throws {
        try await record(.regenerateQuestion(jobId: jobId, order: order, provider: provider))
    }

    func saveDraftQuestion(jobId: String, question: ExamQuestion) async throws {
        try await record(.saveDraftQuestion(jobId: jobId, questionId: question.id))
    }

    func publish(jobId: String, subjectId: String?, newSubjectName: String?) async throws -> PublishedExamResult {
        try await record(.publish(jobId: jobId, subjectId: subjectId, newSubjectName: newSubjectName))
        return publishResult
    }

    func requestBulkConversion(scope: BulkConversionScope, provider: AIProvider, dryRun: Bool) async throws -> BulkConversionEstimate {
        try await record(.requestBulk(scope: scope, provider: provider, dryRun: dryRun))
        return bulkEstimate
    }

    func monthlyUsage() async throws -> AIMonthlyUsage {
        await gate?.pass()
        if let error { throw error }
        return usage
    }

    func updatePublishedQuestion(_ question: ExamQuestion) async throws {
        try await record(.updatePublishedQuestion(questionId: question.id))
    }

    func regeneratePublishedQuestion(questionId: String, provider: AIProvider) async throws {
        try await record(.regeneratePublishedQuestion(questionId: questionId, provider: provider))
    }

    func discard(jobId: String) async throws {
        try await record(.discard(jobId: jobId))
    }

    private func record(_ call: Call) async throws {
        calls.append(call)
        await gate?.pass()
        if let error { throw error }
    }
}

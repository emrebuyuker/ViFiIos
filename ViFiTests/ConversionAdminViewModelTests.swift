import Foundation
import Testing
@testable import ViFi

/// Builders for the conversion admin tests.
enum ConversionFixture {
    static func job(
        id: String = "sub-s1",
        status: ConversionStatus = .ready,
        provider: AIProvider? = .claude,
        error: String? = nil
    ) -> ExamConversion {
        ExamConversion(
            id: id, source: .submission(submissionId: "s1"), kind: .images, status: status, provider: provider,
            attempts: 1, error: error, usage: ConversionUsage(inputTokens: 100, outputTokens: 50, costUsd: 0.42),
            placementNames: ["Uni", "Fak", "Böl", "Ders", "2023 VİZE"], createdAt: nil, readyAt: nil
        )
    }

    static func question(order: Int = 1, needsReview: Bool = false) -> ExamQuestion {
        ExamQuestion(
            id: String(format: "%03d", order), examId: "sub-s1", order: order, label: String(order),
            text: "2 + 2 kaçtır?", speech: "iki artı iki kaçtır", choices: [
                QuestionChoice(label: "A", text: "3"), QuestionChoice(label: "B", text: "4"),
            ],
            figures: [], answer: QuestionAnswer(text: "4", choice: "B", speech: nil), solution: ["2 + 2 = 4"],
            topics: ["toplama"], difficulty: 1, confidence: 0.9, needsReview: needsReview, updatedAt: nil
        )
    }
}

@MainActor
@Suite("ConversionJobsViewModel")
struct ConversionJobsViewModelTests {
    @Test("The ready list loads only ready jobs")
    func loadsReady() async {
        let service = StubExamConversionService()
        service.jobs = [ConversionFixture.job(id: "a"), ConversionFixture.job(id: "b", status: .failed)]
        let viewModel = ConversionJobsViewModel(kind: .ready, service: service)

        await viewModel.loadIfNeeded()

        #expect(viewModel.state.value?.map(\.id) == ["a"])
    }

    @Test("A failed job restarts with the picked provider and leaves the list")
    func restartFailed() async {
        let service = StubExamConversionService()
        service.jobs = [ConversionFixture.job(id: "a", status: .failed, error: "x")]
        let viewModel = ConversionJobsViewModel(kind: .failed, service: service)
        await viewModel.loadIfNeeded()

        let accepted = await viewModel.restart(service.jobs[0], provider: .gemini)

        #expect(accepted)
        #expect(service.calls == [.regenerate(jobId: "a", provider: .gemini)])
        #expect(viewModel.state.value?.isEmpty == true)
    }

    @Test("A failed restart keeps the job and shows the error")
    func restartError() async {
        let service = StubExamConversionService()
        service.jobs = [ConversionFixture.job(id: "a", status: .failed)]
        let viewModel = ConversionJobsViewModel(kind: .failed, service: service)
        await viewModel.loadIfNeeded()
        service.error = ExamConversionError.budgetExceeded

        let accepted = await viewModel.restart(service.jobs[0], provider: .claude)

        #expect(!accepted)
        #expect(viewModel.actionError == ExamConversionError.budgetExceeded.userMessage)
        #expect(viewModel.state.value?.map(\.id) == ["a"])
    }

    @Test("A failed load surfaces an error")
    func failedLoad() async {
        let service = StubExamConversionService()
        service.error = ExamConversionError.offline
        let viewModel = ConversionJobsViewModel(kind: .ready, service: service)

        await viewModel.loadIfNeeded()

        if case .failed = viewModel.state {} else { Issue.record("Expected a failed state") }
    }
}

@MainActor
@Suite("ConversionReviewViewModel")
struct ConversionReviewViewModelTests {
    private func makeViewModel(
        questions: [ExamQuestion] = [ConversionFixture.question(order: 1, needsReview: true), ConversionFixture.question(order: 2)]
    ) -> (ConversionReviewViewModel, StubExamConversionService) {
        let service = StubExamConversionService()
        let job = ConversionFixture.job()
        service.draftsByJob[job.id] = questions
        return (ConversionReviewViewModel(job: job, service: service), service)
    }

    @Test("Loading shows the drafts and counts the ones needing review")
    func loads() async {
        let (viewModel, _) = makeViewModel()

        await viewModel.loadIfNeeded()

        #expect(viewModel.drafts.value?.count == 2)
        #expect(viewModel.needsReviewCount == 1)
    }

    @Test("Saving an edit writes the draft and clears its review flag")
    func saveEdit() async {
        let (viewModel, service) = makeViewModel()
        await viewModel.loadIfNeeded()
        let edited = ConversionFixture.question(order: 1, needsReview: true).withNeedsReview(true)

        let saved = await viewModel.save(edited)

        #expect(saved)
        #expect(service.calls == [.saveDraftQuestion(jobId: "sub-s1", questionId: "001")])
        #expect(viewModel.needsReviewCount == 0)
    }

    @Test("Regenerating one question sends the provider and the question order")
    func regenerateQuestion() async {
        let (viewModel, service) = makeViewModel()
        await viewModel.loadIfNeeded()

        await viewModel.regenerateQuestion(order: 2, provider: .gemini)

        #expect(service.calls == [.regenerateQuestion(jobId: "sub-s1", order: 2, provider: .gemini)])
        #expect(viewModel.infoMessage != nil)
    }

    @Test("Regenerating everything ends the review as regenerating")
    func regenerateAll() async {
        let (viewModel, service) = makeViewModel()
        await viewModel.loadIfNeeded()

        await viewModel.regenerateAll(provider: .claude)

        #expect(service.calls == [.regenerate(jobId: "sub-s1", provider: .claude)])
        #expect(viewModel.outcome == .regenerating)
    }

    @Test("Publishing with the suggested subject sends no subject fields")
    func publishSuggested() async {
        let (viewModel, service) = makeViewModel()
        await viewModel.loadIfNeeded()
        service.publishResult = PublishedExamResult(examId: "e1", questionCount: 2)

        await viewModel.publish()

        #expect(service.calls == [.publish(jobId: "sub-s1", subjectId: nil, newSubjectName: nil)])
        #expect(viewModel.outcome == .published(questionCount: 2))
    }

    @Test("Publishing with an existing or a new subject sends it")
    func publishWithSubject() async {
        let (viewModel, service) = makeViewModel()
        await viewModel.loadIfNeeded()
        viewModel.subjectMode = .existing
        viewModel.subjectId = " calculus-1 "

        await viewModel.publish()

        #expect(service.calls == [.publish(jobId: "sub-s1", subjectId: "calculus-1", newSubjectName: nil)])

        let (second, secondService) = makeViewModel()
        await second.loadIfNeeded()
        second.subjectMode = .new
        second.newSubjectName = "Kuantum Fiziği"

        await second.publish()

        #expect(secondService.calls == [.publish(jobId: "sub-s1", subjectId: nil, newSubjectName: "Kuantum Fiziği")])
    }

    @Test("Publishing with an empty subject field is refused before any call")
    func publishEmptySubject() async {
        let (viewModel, service) = makeViewModel()
        await viewModel.loadIfNeeded()
        viewModel.subjectMode = .existing

        await viewModel.publish()

        #expect(service.calls.isEmpty)
        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.outcome == nil)
    }

    @Test("A publish failure keeps the review open with the message")
    func publishFailure() async {
        let (viewModel, service) = makeViewModel()
        await viewModel.loadIfNeeded()
        service.error = ExamConversionError.notAllowed(message: "Hazır değil")

        await viewModel.publish()

        #expect(viewModel.outcome == nil)
        #expect(viewModel.errorMessage == "Hazır değil")
    }

    @Test("Discarding ends the review as discarded")
    func discard() async {
        let (viewModel, service) = makeViewModel()
        await viewModel.loadIfNeeded()

        await viewModel.discard()

        #expect(service.calls == [.discard(jobId: "sub-s1")])
        #expect(viewModel.outcome == .discarded)
        #expect(!viewModel.canPublish)
    }

    @Test("An exam without drafts cannot be published")
    func emptyCannotPublish() async {
        let (viewModel, service) = makeViewModel(questions: [])
        await viewModel.loadIfNeeded()

        await viewModel.publish()

        #expect(service.calls.isEmpty)
    }
}

@MainActor
@Suite("BulkConversionViewModel")
struct BulkConversionViewModelTests {
    @Test("Estimating needs a scope and a provider, and never queues")
    func estimateIsDryRun() async {
        let service = StubExamConversionService()
        service.bulkEstimate = BulkConversionEstimate(examCount: 12, estimatedCostUsd: 5, jobIds: [])
        let viewModel = BulkConversionViewModel(service: service)
        #expect(!viewModel.canEstimate)
        viewModel.scope = .department(id: "d1")
        #expect(!viewModel.canEstimate)
        viewModel.provider = .claude

        await viewModel.estimate()

        #expect(service.calls == [.requestBulk(scope: .department(id: "d1"), provider: .claude, dryRun: true)])
        #expect(viewModel.phase == .estimated(service.bulkEstimate))
    }

    @Test("Confirming queues for real with the same scope and provider")
    func confirmQueues() async {
        let service = StubExamConversionService()
        service.bulkEstimate = BulkConversionEstimate(examCount: 2, estimatedCostUsd: 1, jobIds: ["exam-1", "exam-2"])
        let viewModel = BulkConversionViewModel(service: service)
        viewModel.scope = .course(id: "c1")
        viewModel.provider = .gemini
        await viewModel.estimate()

        await viewModel.confirm()

        #expect(service.calls.last == .requestBulk(scope: .course(id: "c1"), provider: .gemini, dryRun: false))
        #expect(viewModel.phase == .queued(service.bulkEstimate))
    }

    @Test("Changing the provider drops a previous estimate")
    func changeInvalidates() async {
        let service = StubExamConversionService()
        let viewModel = BulkConversionViewModel(service: service)
        viewModel.scope = .course(id: "c1")
        viewModel.provider = .claude
        await viewModel.estimate()

        viewModel.provider = .gemini

        #expect(viewModel.phase == .idle)
    }

    @Test("An estimate that would pass the $50 cap is flagged")
    func overBudget() async {
        let service = StubExamConversionService()
        service.usage = AIMonthlyUsage(month: "2026-11", costUsd: 45)
        service.bulkEstimate = BulkConversionEstimate(examCount: 30, estimatedCostUsd: 8, jobIds: [])
        let viewModel = BulkConversionViewModel(service: service)
        await viewModel.loadUsage()
        viewModel.scope = .department(id: "d1")
        viewModel.provider = .claude

        await viewModel.estimate()

        #expect(viewModel.estimateExceedsBudget)
    }

    @Test("A failed estimate returns to idle with the message")
    func estimateFailure() async {
        let service = StubExamConversionService()
        service.error = ExamConversionError.permissionDenied
        let viewModel = BulkConversionViewModel(service: service)
        viewModel.scope = .course(id: "c1")
        viewModel.provider = .claude

        await viewModel.estimate()

        #expect(viewModel.phase == .idle)
        #expect(viewModel.errorMessage == ExamConversionError.permissionDenied.userMessage)
    }
}

import Foundation
import Testing
@testable import ViFi

/// Builders for the conversion admin tests.
enum ConversionFixture {
    static func job(
        id: String = "sub-s1",
        status: ConversionStatus = .ready,
        provider: AIProvider? = .claude,
        error: String? = nil,
        originalTitle: String = "2023 VİZE",
        suggestedTitle: String? = "2023 VİZE"
    ) -> ExamConversion {
        ExamConversion(
            id: id, source: .submission(submissionId: "s1"), kind: .images, status: status, provider: provider,
            attempts: 1, error: error, usage: ConversionUsage(inputTokens: 100, outputTokens: 50, costUsd: 0.42),
            placementNames: ["Uni", "Fak", "Böl", "Ders", originalTitle], createdAt: nil, readyAt: nil,
            originalTitle: originalTitle, suggestedTitle: suggestedTitle
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
        questions: [ExamQuestion] = [ConversionFixture.question(order: 1, needsReview: true), ConversionFixture.question(order: 2)],
        job: ExamConversion = ConversionFixture.job()
    ) -> (ConversionReviewViewModel, StubExamConversionService) {
        let service = StubExamConversionService()
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

        #expect(service.calls == [.publish(jobId: "sub-s1", subjectId: nil, newSubjectName: nil, examTitle: "2023 VİZE")])
        #expect(viewModel.outcome == .published(questionCount: 2))
    }

    @Test("Publishing with an existing or a new subject sends it")
    func publishWithSubject() async {
        let (viewModel, service) = makeViewModel()
        await viewModel.loadIfNeeded()
        viewModel.subjectMode = .existing
        viewModel.subjectId = " calculus-1 "

        await viewModel.publish()

        #expect(service.calls == [.publish(jobId: "sub-s1", subjectId: "calculus-1", newSubjectName: nil, examTitle: "2023 VİZE")])

        let (second, secondService) = makeViewModel()
        await second.loadIfNeeded()
        second.subjectMode = .new
        second.newSubjectName = "Kuantum Fiziği"

        await second.publish()

        #expect(secondService.calls == [.publish(jobId: "sub-s1", subjectId: nil, newSubjectName: "Kuantum Fiziği", examTitle: "2023 VİZE")])
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

    @Test("The title editor starts from the server's suggestion (K28)")
    func titleDefaultsToSuggestion() async {
        let (viewModel, _) = makeViewModel(job: ConversionFixture.job(originalTitle: "2019 FİZİK QUIZ 5", suggestedTitle: "2019 KISA SINAV 5"))

        #expect(viewModel.titleYear == "2019")
        #expect(viewModel.titleEntryId == "kisa-sinav")
        #expect(viewModel.titleNumber == "5")
        #expect(viewModel.examTitle == "2019 KISA SINAV 5")
        #expect(viewModel.titleProblem == nil)
        #expect(viewModel.job.originalTitle == "2019 FİZİK QUIZ 5")
    }

    @Test("Without a suggestion a list name must be picked before publishing (K28)")
    func titleRequiredWithoutSuggestion() async {
        let (viewModel, service) = makeViewModel(job: ConversionFixture.job(originalTitle: "DERS NOTU", suggestedTitle: nil))
        await viewModel.loadIfNeeded()

        #expect(viewModel.titleEntryId == nil)
        #expect(viewModel.examTitle == nil)
        #expect(viewModel.titleProblem != nil)
        #expect(!viewModel.canPublish)
        await viewModel.publish()
        #expect(service.calls.isEmpty)

        viewModel.titleEntryId = "calisma-sorulari"
        #expect(viewModel.canPublish)
        await viewModel.publish()
        #expect(service.calls == [.publish(jobId: "sub-s1", subjectId: nil, newSubjectName: nil, examTitle: "ÇALIŞMA SORULARI")])
    }

    @Test("The admin's edited title is validated and sent (K28, K29)")
    func titleEdits() async {
        let (viewModel, service) = makeViewModel()
        await viewModel.loadIfNeeded()

        viewModel.titleYear = "2017-2018"
        #expect(viewModel.examTitle == nil)
        #expect(!viewModel.canPublish)
        viewModel.titleYear = "19"
        #expect(viewModel.examTitle == nil)
        viewModel.titleYear = " "
        #expect(viewModel.examTitle == "VİZE")
        viewModel.titleYear = "2020"

        viewModel.titleNumber = "100"
        #expect(viewModel.examTitle == nil)
        viewModel.titleNumber = "0"
        #expect(viewModel.examTitle == nil)
        viewModel.titleNumber = "2"
        viewModel.titleEntryId = "yaz-okulu-final"
        #expect(viewModel.examTitle == "2020 YAZ OKULU FİNAL 2")

        // "KISA SINAV" + 2 is the list's own "KISA SINAV 2"; a numbered name takes no extra number.
        viewModel.titleEntryId = "kisa-sinav"
        #expect(viewModel.examTitle == "2020 KISA SINAV 2")
        viewModel.titleEntryId = "kisa-sinav-2"
        #expect(viewModel.examTitle == nil)
        viewModel.titleNumber = ""
        #expect(viewModel.examTitle == "2020 KISA SINAV 2")

        await viewModel.publish()
        #expect(service.calls == [.publish(jobId: "sub-s1", subjectId: nil, newSubjectName: nil, examTitle: "2020 KISA SINAV 2")])
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

@MainActor
@Suite("ConversionReviewViewModel regeneration polling")
struct ConversionReviewPollingTests {
    private static let now = Date(timeIntervalSince1970: 1_000)
    private static let lease = Date(timeIntervalSince1970: 2_000)

    private func question(
        order: Int = 1, lease: Date? = nil, error: String? = nil, updatedAt: Date? = nil
    ) -> ExamQuestion {
        var question = ConversionFixture.question(order: order)
        question.regeneratingUntil = lease
        question.regenerationError = error
        return ExamQuestion(
            id: question.id, examId: question.examId, order: order, label: question.label, text: question.text,
            speech: question.speech, choices: question.choices, figures: [], answer: question.answer,
            solution: [], topics: [], difficulty: 1, confidence: nil, needsReview: false, updatedAt: updatedAt,
            regeneratingUntil: lease, regenerationError: error
        )
    }

    private func makeViewModel(window: Duration = .milliseconds(200)) -> (ConversionReviewViewModel, StubExamConversionService) {
        let service = StubExamConversionService()
        let job = ConversionFixture.job()
        service.draftsByJob[job.id] = [question()]
        let viewModel = ConversionReviewViewModel(
            job: job, service: service, now: { Date(timeIntervalSince1970: 1_000) }, pollInterval: .milliseconds(5), pollWindow: window
        )
        return (viewModel, service)
    }

    @Test("A draft is regenerating only while its lease is in the future")
    func stateMapping() {
        let (viewModel, _) = makeViewModel()

        #expect(viewModel.isRegenerating(question(lease: Self.lease)))
        #expect(!viewModel.isRegenerating(question(lease: Self.now.addingTimeInterval(-1))))
        #expect(!viewModel.isRegenerating(question()))
    }

    @Test("Polling ends once the lease it saw is gone, and the list shows the new draft")
    func stopsWhenLeaseGone() async {
        let (viewModel, service) = makeViewModel()
        await viewModel.loadIfNeeded()
        service.draftResponses = [
            [question(lease: Self.lease)], [question(lease: Self.lease)], [question(updatedAt: Date(timeIntervalSince1970: 5))],
        ]

        await viewModel.regenerateQuestion(order: 1, provider: .claude)
        await viewModel.waitForPolling()

        #expect(service.draftCallCount == 1 + 3)
        #expect(viewModel.drafts.value?.first?.regeneratingUntil == nil)
        #expect(viewModel.drafts.value?.first?.updatedAt == Date(timeIntervalSince1970: 5))
    }

    @Test("Polling ends on a new error even when no lease was seen")
    func stopsOnError() async {
        let (viewModel, service) = makeViewModel()
        await viewModel.loadIfNeeded()
        service.draftResponses = [[question()], [question(error: "Model yanıt vermedi")]]

        await viewModel.regenerateQuestion(order: 1, provider: .claude)
        await viewModel.waitForPolling()

        #expect(service.draftCallCount == 1 + 2)
        #expect(viewModel.drafts.value?.first?.regenerationError == "Model yanıt vermedi")
    }

    @Test("Polling gives up after the window while the lease keeps running")
    func stopsAtWindow() async {
        let (viewModel, service) = makeViewModel(window: .milliseconds(40))
        await viewModel.loadIfNeeded()
        service.draftsByJob[ConversionFixture.job().id] = [question(lease: Self.lease)]

        await viewModel.regenerateQuestion(order: 1, provider: .claude)
        await viewModel.waitForPolling()

        #expect(service.draftCallCount == 1 + 8)
    }

    @Test("Leaving the screen cancels the polling")
    func cancelStops() async {
        let (viewModel, service) = makeViewModel(window: .seconds(60))
        await viewModel.loadIfNeeded()
        service.draftsByJob[ConversionFixture.job().id] = [question(lease: Self.lease)]

        await viewModel.regenerateQuestion(order: 1, provider: .claude)
        viewModel.stopPolling()
        await viewModel.waitForPolling()
        let callsAfterStop = service.draftCallCount
        try? await Task.sleep(for: .milliseconds(40))

        #expect(service.draftCallCount == callsAfterStop)
    }

    @Test("Stop rules: running lease continues; seen-then-gone, new error and a rewritten draft stop")
    func stopRules() {
        let baseline = question(updatedAt: Date(timeIntervalSince1970: 1))
        let stop = ConversionReviewViewModel.pollShouldStop

        #expect(!stop(question(lease: Self.lease), baseline, false, Self.now))
        #expect(!stop(baseline, baseline, false, Self.now))
        #expect(stop(baseline, baseline, true, Self.now))
        #expect(stop(question(error: "x", updatedAt: Date(timeIntervalSince1970: 1)), baseline, false, Self.now))
        #expect(stop(question(updatedAt: Date(timeIntervalSince1970: 9)), baseline, false, Self.now))
        #expect(stop(nil, baseline, false, Self.now))
        // A stale error from an earlier run does not end the next one before the server claims the draft.
        let stale = question(error: "eski", updatedAt: Date(timeIntervalSince1970: 1))
        #expect(!stop(stale, stale, false, Self.now))
    }
}

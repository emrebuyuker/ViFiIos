import Foundation
import Testing
@testable import ViFi

@Suite("PracticeSessionViewModel", .timeLimit(.minutes(1)))
struct PracticeSessionViewModelTests {
    private let analytics = AnalyticsSpy()

    private func makeViewModel(_ service: StubPracticeService) -> PracticeSessionViewModel {
        PracticeSessionViewModel(selection: PracticeFixture.selection, service: service, analytics: analytics)
    }

    // MARK: - Start and prefetch

    @Test("Starting shows the first question, prefetches the next (Premium) and reports the start once")
    func startAndPrefetch() async {
        let service = StubPracticeService(results: [
            .batch(PracticeFixture.batch(ids: ["e1-001"], remaining: nil)),
            .batch(PracticeFixture.batch(ids: ["e1-002"], remaining: nil)),
        ])
        let viewModel = makeViewModel(service)

        await viewModel.start()
        await viewModel.start()
        await Task.yield()

        #expect(viewModel.phase == .question)
        #expect(viewModel.current?.id == "e1-001")
        #expect(analytics.events == [.practiceStarted(examType: .final, scope: .turkey)])
        await waitForRequests(service, count: 2)
        #expect(service.requests.map(\.count) == [1, 1])
        #expect(service.requests[0].exclude.isEmpty)
        #expect(service.requests[1].exclude == ["e1-001"])
    }

    @Test("The next question is the prefetched one and the following request excludes everything seen")
    func nextUsesThePrefetch() async {
        let service = StubPracticeService(results: [
            .batch(PracticeFixture.batch(ids: ["e1-001"], remaining: nil)),
            .batch(PracticeFixture.batch(ids: ["e1-002"], remaining: nil)),
            .batch(PracticeFixture.batch(ids: ["e1-003"], remaining: nil)),
        ])
        let viewModel = makeViewModel(service)
        await viewModel.start()

        await viewModel.next()
        #expect(viewModel.current?.id == "e1-002")
        await waitForRequests(service, count: 3)

        await viewModel.next()
        #expect(viewModel.current?.id == "e1-003")
        #expect(service.requests[2].exclude == ["e1-001", "e1-002"])
    }

    @Test("Questions are numbered 1, 2, 3… in the session, and starting over begins at 1 again")
    func runningNumber() async {
        let service = StubPracticeService(results: [
            .batch(PracticeFixture.batch(ids: ["e1-004"], remaining: nil)),
            .batch(PracticeFixture.batch(ids: ["e2-001"], remaining: nil)),
            .batch(PracticeFixture.batch(ids: [], remaining: nil)),
            .batch(PracticeFixture.batch(ids: ["e1-004"], remaining: nil)),
        ])
        let viewModel = makeViewModel(service)
        #expect(viewModel.questionNumber == 0)

        await viewModel.start()
        #expect(viewModel.questionNumber == 1)
        await waitForRequests(service, count: 2)
        await viewModel.next()
        #expect(viewModel.questionNumber == 2)
        await waitForRequests(service, count: 3)
        await viewModel.next()
        #expect(viewModel.phase == .exhausted)
        #expect(viewModel.questionNumber == 2)

        await viewModel.restart()
        #expect(viewModel.questionNumber == 1)
    }

    @Test("Revealing flips the answer; moving on hides it again; only the first reveal of a question is counted")
    func reveal() async {
        let service = StubPracticeService(results: [
            .batch(PracticeFixture.batch(ids: ["e1-001"], remaining: nil)),
            .batch(PracticeFixture.batch(ids: ["e1-002"], remaining: nil)),
        ])
        let viewModel = makeViewModel(service)
        await viewModel.start()

        viewModel.toggleAnswer()
        viewModel.toggleAnswer()
        viewModel.toggleAnswer()
        #expect(viewModel.isAnswerRevealed)
        await viewModel.next()
        #expect(!viewModel.isAnswerRevealed)
        viewModel.toggleAnswer()

        #expect(analytics.events.filter { $0 == .practiceAnswerRevealed }.count == 2)
    }

    // MARK: - Free limit and Premium

    @Test("Free users never prefetch, so leaving a session cannot spend a question they did not see")
    func freeUsersDoNotPrefetch() async {
        let service = StubPracticeService(results: [
            .batch(PracticeFixture.batch(ids: ["e1-001"], remaining: 4)),
            .batch(PracticeFixture.batch(ids: ["e1-002"], remaining: 3)),
        ])
        let viewModel = makeViewModel(service)

        await viewModel.start()
        await settleTasks()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(service.requests.count == 1)
        // 5 free per day, one on screen: 4 left.
        #expect(viewModel.remainingToday == 4)

        await viewModel.next()
        #expect(viewModel.current?.id == "e1-002")
        #expect(viewModel.remainingToday == 3)
        #expect(service.requests.count == 2)
        #expect(service.requests[1].exclude == ["e1-001"])
    }

    @Test("Premium has no counter")
    func premiumNoCounter() async {
        let service = StubPracticeService(fallback: .batch(PracticeFixture.batch(ids: ["e1-001"], remaining: nil)))
        let viewModel = makeViewModel(service)

        await viewModel.start()

        #expect(viewModel.remainingToday == nil)
    }

    @Test("When the last free question is out, the next tap lands on the limit state and is counted once")
    func limitReached() async {
        let service = StubPracticeService(results: [
            .batch(PracticeFixture.batch(ids: ["e1-001"], remaining: 1)),
            .batch(PracticeFixture.batch(ids: ["e1-002"], remaining: 0)),
        ])
        let viewModel = makeViewModel(service)
        await viewModel.start()

        await viewModel.next()
        #expect(viewModel.current?.id == "e1-002")
        #expect(viewModel.phase == .question)

        await viewModel.next()
        #expect(viewModel.phase == .limitReached)
        #expect(viewModel.current == nil)
        await viewModel.next()
        #expect(analytics.events.filter { $0 == .practiceLimitReached }.count == 1)
        #expect(service.requests.count == 2, "No request once the limit is known")
    }

    @Test("A limit reached on the very first call shows the limit state at once")
    func limitOnStart() async {
        let service = StubPracticeService(fallback: .batch(PracticeFixture.batch(ids: [], remaining: 0, limitReached: true)))
        let viewModel = makeViewModel(service)

        await viewModel.start()

        #expect(viewModel.phase == .limitReached)
        #expect(analytics.events.contains(.practiceLimitReached))
    }

    @Test("Opening the paywall from the limit state is reported")
    func paywallEvent() {
        let viewModel = makeViewModel(StubPracticeService())

        viewModel.paywallOpened()

        #expect(analytics.events == [.practicePaywallOpened])
    }

    // MARK: - Exhausted pool

    @Test("An exhausted pool is reported, and starting over forgets the seen ids")
    func exhaustedAndRestart() async {
        let service = StubPracticeService(results: [
            .batch(PracticeFixture.batch(ids: ["e1-001"], remaining: nil)),
            .batch(PracticeFixture.batch(ids: [], remaining: nil)),
            .batch(PracticeFixture.batch(ids: ["e1-001"], remaining: nil)),
        ])
        let viewModel = makeViewModel(service)
        await viewModel.start()
        await waitForRequests(service, count: 2)

        await viewModel.next()
        #expect(viewModel.phase == .exhausted)

        await viewModel.restart()
        #expect(viewModel.phase == .question)
        #expect(viewModel.current?.id == "e1-001")
        #expect(service.requests[2].exclude.isEmpty)
    }

    @Test("A server that returns only seen questions counts as exhausted")
    func seenOnlyIsExhausted() async {
        let service = StubPracticeService(results: [
            .batch(PracticeFixture.batch(ids: ["e1-001"], remaining: nil)),
            .batch(PracticeFixture.batch(ids: ["e1-001"], remaining: nil)),
        ])
        let viewModel = makeViewModel(service)
        await viewModel.start()
        await waitForRequests(service, count: 2)

        await viewModel.next()

        #expect(viewModel.phase == .exhausted)
    }

    @Test("exclude is capped at the newest 300 seen ids")
    func excludeCap() async {
        let ids = (1...320).map { String(format: "e1-%03d", $0) }
        var results: [StubPracticeService.Result] = ids.map { .batch(PracticeFixture.batch(ids: [$0], remaining: nil)) }
        results.append(.batch(PracticeFixture.batch(ids: [], remaining: nil)))
        let service = StubPracticeService(results: results)
        let viewModel = makeViewModel(service)
        await viewModel.start()

        for _ in 1..<320 {
            await waitForRequests(service, count: service.requests.count)
            await viewModel.next()
        }

        #expect(viewModel.excludedIds.count == PracticeLimits.maxExclude)
        #expect(viewModel.excludedIds.last == "e1-320")
        #expect(viewModel.excludedIds.first == "e1-021")
    }

    // MARK: - Errors

    @Test("A failed first load shows the message, and retrying recovers")
    func failureAndRetry() async {
        let service = StubPracticeService(results: [
            .failure(.offline),
            .batch(PracticeFixture.batch(ids: ["e1-001"], remaining: nil)),
        ])
        let viewModel = makeViewModel(service)

        await viewModel.start()
        #expect(viewModel.phase == .failed(message: PracticeError.offline.userMessage))

        await viewModel.next()
        #expect(viewModel.phase == .question)
        #expect(viewModel.current?.id == "e1-001")
    }

    @Test("A failed prefetch stays silent until the user asks for the next question, then the call is retried")
    func prefetchFailureIsSilent() async {
        let service = StubPracticeService(results: [
            .batch(PracticeFixture.batch(ids: ["e1-001"], remaining: nil)),
            .failure(.offline),
            .batch(PracticeFixture.batch(ids: ["e1-002"], remaining: nil)),
        ])
        let viewModel = makeViewModel(service)
        await viewModel.start()
        await waitForRequests(service, count: 2)

        #expect(viewModel.phase == .question)
        #expect(viewModel.current?.id == "e1-001")

        await viewModel.next()
        #expect(viewModel.current?.id == "e1-002")
        #expect(viewModel.phase == .question)
    }

    // MARK: - Helpers

    /// Waits until the stub has seen `count` requests (the prefetch runs in a task).
    private func waitForRequests(_ service: StubPracticeService, count: Int) async {
        for _ in 0..<200 where service.requests.count < count {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private func settleTasks() async {
        for _ in 0..<10 { await Task.yield() }
    }
}

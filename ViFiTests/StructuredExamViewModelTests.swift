import Foundation
import Testing
@testable import ViFi

@Suite("StructuredExamViewModel", .timeLimit(.minutes(1)))
final class StructuredExamViewModelTests {
    private let storage: TemporaryDefaults
    private let recents: RecentExamsStore
    private let analytics = AnalyticsSpy()
    private let reader = StubExamQuestionReader()
    private let path = Fixture.imagesExam

    init() throws {
        storage = try TemporaryDefaults()
        recents = RecentExamsStore(defaults: storage.defaults)
    }

    private func makeViewModel() -> StructuredExamViewModel {
        StructuredExamViewModel(path: path, kind: .images, reader: reader, recents: recents, analytics: analytics)
    }

    private var examId: String { path.components.last ?? "" }

    // MARK: - Loading

    @Test("A new view model is loading and reads nothing yet")
    func initialState() {
        let viewModel = makeViewModel()

        #expect(viewModel.state == .loading)
        #expect(viewModel.questions.isEmpty)
        #expect(reader.requestedExamIds.isEmpty)
    }

    @Test("Loading reads only this exam's questions, and records the visit once")
    func loadSuccess() async {
        reader.questionsByExam[examId] = StructuredExamFixture.questions(count: 3, examId: examId)
        let viewModel = makeViewModel()

        await viewModel.load()
        await viewModel.load()

        #expect(viewModel.questions.map(\.order) == [1, 2, 3])
        #expect(reader.requestedExamIds == [examId, examId])
        #expect(recents.exams.map(\.path) == [path])
        #expect(analytics.events == [.structuredExamOpened(questionCount: 3)])
    }

    @Test("An exam without questions loads empty and records no visit")
    func emptyExam() async {
        let viewModel = makeViewModel()

        await viewModel.load()

        #expect(viewModel.state == .loaded([]))
        #expect(recents.exams.isEmpty)
        #expect(analytics.events.isEmpty)
    }

    @Test("A failed read shows the error and records nothing; a retry can still succeed")
    func loadFailureThenRetry() async {
        reader.error = ArchiveError.offline
        let viewModel = makeViewModel()

        await viewModel.load()

        #expect(viewModel.state == .failed(message: ArchiveError.offline.userMessage))
        #expect(recents.exams.isEmpty)
        #expect(analytics.events.isEmpty)

        reader.error = nil
        reader.questionsByExam[examId] = StructuredExamFixture.questions(count: 1, examId: examId)
        await viewModel.load()

        #expect(viewModel.questions.count == 1)
    }

    @Test("Questions on screen stay when a reload fails")
    func reloadFailureKeepsQuestions() async {
        reader.questionsByExam[examId] = StructuredExamFixture.questions(count: 2, examId: examId)
        let viewModel = makeViewModel()
        await viewModel.load()

        reader.error = ArchiveError.offline
        await viewModel.load()

        #expect(viewModel.questions.count == 2)
    }

    @Test("loadIfNeeded does not read again once questions are available")
    func loadIfNeeded() async {
        reader.questionsByExam[examId] = StructuredExamFixture.questions(count: 2, examId: examId)
        let viewModel = makeViewModel()

        await viewModel.loadIfNeeded()
        await viewModel.loadIfNeeded()

        #expect(reader.requestedExamIds == [examId])
    }

    @Test("A second load while one is in flight is ignored")
    func concurrentLoadIgnored() async {
        let gate = AsyncGate()
        reader.gate = gate
        reader.questionsByExam[examId] = StructuredExamFixture.questions(count: 2, examId: examId)
        let viewModel = makeViewModel()

        let first = Task { await viewModel.load() }
        await gate.waitForArrival()
        await viewModel.load()
        gate.open()
        await first.value

        #expect(reader.requestedExamIds == [examId])
    }

    // MARK: - Answers

    @Test("Revealing an answer shows it and counts it once, however often it is toggled")
    func revealCountedOnce() {
        let viewModel = makeViewModel()

        viewModel.toggleAnswer(order: 2)
        #expect(viewModel.isAnswerRevealed(order: 2))
        #expect(!viewModel.isAnswerRevealed(order: 1))

        viewModel.toggleAnswer(order: 2)
        #expect(!viewModel.isAnswerRevealed(order: 2))
        viewModel.toggleAnswer(order: 2)
        viewModel.toggleAnswer(order: 1)

        #expect(analytics.events == [.answerRevealed(order: 2), .answerRevealed(order: 1)])
    }

    @Test("Support context names the exam")
    func supportContext() {
        #expect(makeViewModel().supportContext.hasPrefix("Sınav: "))
    }
}

/// Questions for the structured-exam tests.
enum StructuredExamFixture {
    static func question(order: Int, examId: String, text: String = "$x$ kaçtır?") -> ExamQuestion {
        ExamQuestion(
            id: "\(examId)-\(String(format: "%03d", order))", examId: examId, order: order, label: "\(order)",
            text: text, speech: "x kaçtır?", choices: [], figures: [],
            answer: QuestionAnswer(text: "$1$", choice: nil, speech: "bir"), solution: ["$x = 1$"],
            topics: [], difficulty: 1, confidence: nil, needsReview: false, updatedAt: nil
        )
    }

    static func questions(count: Int, examId: String) -> [ExamQuestion] {
        (1...count).map { question(order: $0, examId: examId) }
    }
}

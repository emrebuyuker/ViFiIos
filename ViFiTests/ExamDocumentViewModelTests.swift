import Foundation
import Testing
@testable import ViFi

/// Every test records into its own `UserDefaults` suite, deleted afterwards.
@Suite("ExamDocumentViewModel", .timeLimit(.minutes(1)))
final class ExamDocumentViewModelTests {
    private let storage: TemporaryDefaults
    private let recents: RecentExamsStore
    private let analytics = AnalyticsSpy()

    init() throws {
        storage = try TemporaryDefaults()
        recents = RecentExamsStore(defaults: storage.defaults)
    }

    // MARK: - Loading

    @Test("A new view model is loading")
    func initialState() {
        let viewModel = makeViewModel(repository: StubArchiveRepository())

        #expect(viewModel.path == Fixture.imagesExam)
        #expect(viewModel.state == .loading)
        #expect(viewModel.document == nil)
    }

    @Test("Loading shows the exam's document", arguments: ExamKind.allCases)
    func loadSuccess(_ kind: ExamKind) async {
        let document = Fixture.document(kind: kind)
        let repository = StubArchiveRepository(documents: [.success(document)])
        let viewModel = makeViewModel(repository: repository)

        await viewModel.load()

        #expect(viewModel.state == .loaded(document))
        #expect(repository.requestedDocumentPaths == [Fixture.imagesExam])
        #expect(recents.exams.map(\.path) == [Fixture.imagesExam])
        #expect(recents.exams.map(\.kind) == [kind])
        #expect(analytics.events == [.examOpened(kind: kind)])
    }

    @Test("The visit is recorded only once, however often the document loads")
    func visitRecordedOnce() async throws {
        let repository = StubArchiveRepository(documents: [.success(Fixture.document())])
        let viewModel = makeViewModel(repository: repository)
        await viewModel.load()
        let firstVisit = try #require(recents.exams.first)

        await viewModel.load()

        #expect(repository.requestedDocumentPaths.count == 2)
        #expect(recents.exams == [firstVisit])
        #expect(analytics.events == [.examOpened(kind: .images)])
    }

    @Test("A failed load shows the error and records nothing")
    func loadFailure() async {
        let viewModel = makeViewModel(repository: StubArchiveRepository(documents: [.failure(ArchiveError.offline)]))

        await viewModel.load()

        #expect(viewModel.state == .failed(message: ArchiveError.offline.userMessage))
        #expect(recents.exams.isEmpty)
        #expect(analytics.events.isEmpty)
    }

    @Test("A file host error shows its user-facing message")
    func fileUnavailable() async {
        let error = ArchiveError.fileUnavailable(statusCode: 402)
        let viewModel = makeViewModel(repository: StubArchiveRepository(documents: [.failure(error)]))

        await viewModel.load()

        #expect(viewModel.state == .failed(message: error.userMessage))
    }

    @Test("Retrying after a failure loads the document and records the visit once")
    func retryAfterFailure() async {
        let document = Fixture.document(kind: .pdf, at: Fixture.pdfExam, fileCount: 1)
        let repository = StubArchiveRepository(documents: [.failure(ArchiveError.offline), .success(document)])
        let viewModel = makeViewModel(path: Fixture.pdfExam, repository: repository)
        await viewModel.load()

        await viewModel.load()

        #expect(viewModel.state == .loaded(document))
        #expect(recents.exams.map(\.path) == [Fixture.pdfExam])
        #expect(analytics.events == [.examOpened(kind: .pdf)])
    }

    @Test("A failed reload keeps the document on screen")
    func failedReloadKeepsDocument() async {
        let document = Fixture.document()
        let repository = StubArchiveRepository(documents: [.success(document), .failure(ArchiveError.offline)])
        let viewModel = makeViewModel(repository: repository)
        await viewModel.load()

        await viewModel.load()

        #expect(viewModel.state == .loaded(document))
        #expect(analytics.events == [.examOpened(kind: .images)])
    }

    @Test("A cancelled load stays loading and records nothing")
    func cancelledLoad() async {
        let viewModel = makeViewModel(repository: StubArchiveRepository(documents: [.failure(CancellationError())]))

        await viewModel.load()

        #expect(viewModel.state == .loading)
        #expect(recents.exams.isEmpty)
        #expect(analytics.events.isEmpty)
    }

    @Test("loadIfNeeded does not fetch a document that is already loaded")
    func loadIfNeeded() async {
        let repository = StubArchiveRepository(documents: [.success(Fixture.document())])
        let viewModel = makeViewModel(repository: repository)

        await viewModel.loadIfNeeded()
        await viewModel.loadIfNeeded()

        #expect(repository.requestedDocumentPaths.count == 1)
    }

    @Test("A load while another one is in flight is ignored")
    func overlappingLoad() async {
        let gate = AsyncGate()
        let document = Fixture.document()
        let repository = StubArchiveRepository(documents: [.success(document)], gate: gate)
        let viewModel = makeViewModel(repository: repository)
        let firstLoad = Task { await viewModel.load() }
        await gate.waitForArrival()

        await viewModel.load()

        #expect(repository.requestedDocumentPaths.count == 1)
        #expect(viewModel.state == .loading)

        gate.open()
        await firstLoad.value

        #expect(viewModel.state == .loaded(document))
        #expect(analytics.events == [.examOpened(kind: .images)])
    }

    // MARK: - Sharing

    @Test("Sharing is tracked with the document's kind once it has loaded")
    func recordShare() async {
        let document = Fixture.document(kind: .pdf, at: Fixture.pdfExam, fileCount: 1)
        let viewModel = makeViewModel(path: Fixture.pdfExam, repository: StubArchiveRepository(documents: [.success(document)]))

        viewModel.recordShare()
        await viewModel.load()
        viewModel.recordShare()

        #expect(analytics.events == [.examOpened(kind: .pdf), .examShared(kind: .pdf)])
    }

    // MARK: - Helpers

    private func makeViewModel(
        path: ArchivePath = Fixture.imagesExam,
        repository: StubArchiveRepository
    ) -> ExamDocumentViewModel {
        ExamDocumentViewModel(path: path, repository: repository, recents: recents, analytics: analytics)
    }
}

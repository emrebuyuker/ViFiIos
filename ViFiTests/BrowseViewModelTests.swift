import Foundation
import Testing
@testable import ViFi

@Suite("BrowseViewModel", .timeLimit(.minutes(1)))
struct BrowseViewModelTests {
    private let universities = Fixture.universities([
        "BOZOK ÜNİVERSİTESİ",
        "IĞDIR ÜNİVERSİTESİ",
        "İSTANBUL ÜNİVERSİTESİ",
        "KOCAELİ ÜNİVERSİTESİ",
        "KÜTAHYA DUMLUPINAR ÜNİVERSİTESİ",
        "SAKARYA ÜNİVERSİTESİ",
    ])

    // MARK: - Live updates

    @Test("An archive change re-reads the list, replacing a stale first answer")
    func archiveChangeRefreshes() async {
        let fresh = Array(universities.prefix(2))
        let repository = StubArchiveRepository(items: [.success(universities), .success(fresh)])
        let (changes, continuation) = AsyncStream<Void>.makeStream()
        repository.changes = changes
        let viewModel = BrowseViewModel(path: .root, repository: repository)
        await viewModel.load()

        continuation.yield()
        continuation.finish()
        await viewModel.refreshOnArchiveChanges()

        #expect(viewModel.state == .loaded(fresh))
        #expect(repository.requestedItemPaths == [.root, .root])
    }

    @Test("A change during the initial load is ignored; the load already reads the newest data")
    func archiveChangeWhileLoadingIsIgnored() async {
        let repository = StubArchiveRepository(items: [.success(universities)])
        let (changes, continuation) = AsyncStream<Void>.makeStream()
        repository.changes = changes
        let viewModel = BrowseViewModel(path: .root, repository: repository)

        continuation.yield()
        continuation.finish()
        await viewModel.refreshOnArchiveChanges()

        #expect(viewModel.state == .loading)
        #expect(repository.requestedItemPaths.isEmpty)
    }

    // MARK: - Loading

    @Test("A new view model is loading and shows nothing")
    func initialState() {
        let viewModel = BrowseViewModel(path: .root, repository: StubArchiveRepository())

        #expect(viewModel.path == .root)
        #expect(viewModel.state == .loading)
        #expect(viewModel.visibleItems.isEmpty)
    }

    @Test("Loading shows the entries listed under the path")
    func loadSuccess() async {
        let repository = StubArchiveRepository(items: [.success(universities)])
        let viewModel = BrowseViewModel(path: .root, repository: repository)

        await viewModel.load()

        #expect(viewModel.state == .loaded(universities))
        #expect(viewModel.visibleItems == universities)
        #expect(repository.requestedItemPaths == [.root])
    }

    @Test("Loading asks for the view model's own path")
    func loadRequestsOwnPath() async {
        let repository = StubArchiveRepository()
        let viewModel = BrowseViewModel(path: Fixture.lesson, repository: repository)

        await viewModel.load()

        #expect(repository.requestedItemPaths == [Fixture.lesson])
    }

    @Test("A list without entries loads as empty")
    func loadEmpty() async {
        let viewModel = BrowseViewModel(path: Fixture.lesson, repository: StubArchiveRepository(items: [.success([])]))

        await viewModel.load()

        #expect(viewModel.state == .loaded([]))
        #expect(viewModel.visibleItems.isEmpty)
    }

    @Test("A failed load shows the error's user-facing message", arguments: [
        ArchiveError.offline,
        .permissionDenied,
        .notFound,
        .unknown(message: "Beklenmeyen bir hata oluştu."),
    ])
    func loadFailure(_ error: ArchiveError) async {
        let viewModel = BrowseViewModel(path: .root, repository: StubArchiveRepository(items: [.failure(error)]))

        await viewModel.load()

        #expect(viewModel.state == .failed(message: error.userMessage))
        #expect(viewModel.visibleItems.isEmpty)
    }

    @Test("Retrying after a failure shows the entries")
    func retryAfterFailure() async {
        let repository = StubArchiveRepository(items: [.failure(ArchiveError.offline), .success(universities)])
        let viewModel = BrowseViewModel(path: .root, repository: repository)
        await viewModel.load()

        await viewModel.load()

        #expect(viewModel.state == .loaded(universities))
        #expect(repository.requestedItemPaths.count == 2)
    }

    @Test("A cancelled load stays loading so the next appearance retries")
    func cancelledLoad() async {
        let viewModel = BrowseViewModel(path: .root, repository: StubArchiveRepository(items: [.failure(CancellationError())]))

        await viewModel.load()

        #expect(viewModel.state == .loading)
    }

    @Test("A load while another one is in flight is ignored")
    func overlappingLoad() async {
        let gate = AsyncGate()
        let repository = StubArchiveRepository(items: [.success(universities)], gate: gate)
        let viewModel = BrowseViewModel(path: .root, repository: repository)
        let firstLoad = Task { await viewModel.load() }
        await gate.waitForArrival()

        await viewModel.load()
        await viewModel.refresh()

        #expect(repository.requestedItemPaths.count == 1)
        #expect(viewModel.state == .loading)

        gate.open()
        await firstLoad.value

        #expect(viewModel.state == .loaded(universities))
        #expect(repository.requestedItemPaths.count == 1)
    }

    // MARK: - Refreshing

    @Test("Refreshing keeps the current entries on screen until the new ones arrive")
    func refreshKeepsItemsWhileInFlight() async {
        let gate = AsyncGate()
        let refreshed = Array(universities.prefix(2))
        let repository = StubArchiveRepository(items: [.success(universities), .success(refreshed)])
        let viewModel = BrowseViewModel(path: .root, repository: repository)
        await viewModel.load()
        repository.gate = gate

        let refresh = Task { await viewModel.refresh() }
        await gate.waitForArrival()

        #expect(viewModel.state == .loaded(universities))

        gate.open()
        await refresh.value

        #expect(viewModel.state == .loaded(refreshed))
    }

    @Test("A failed refresh keeps the entries already shown")
    func failedRefreshKeepsItems() async {
        let repository = StubArchiveRepository(items: [.success(universities), .failure(ArchiveError.offline)])
        let viewModel = BrowseViewModel(path: .root, repository: repository)
        await viewModel.load()

        await viewModel.refresh()

        #expect(viewModel.state == .loaded(universities))
        #expect(repository.requestedItemPaths.count == 2)
    }

    @Test("A failed refresh with nothing on screen shows the error")
    func failedRefreshWithoutItems() async {
        let repository = StubArchiveRepository(items: [.failure(ArchiveError.offline)])
        let viewModel = BrowseViewModel(path: .root, repository: repository)
        await viewModel.load()

        await viewModel.refresh()

        #expect(viewModel.state == .failed(message: ArchiveError.offline.userMessage))
    }

    @Test("Refreshing after a failure shows the entries")
    func refreshAfterFailure() async {
        let repository = StubArchiveRepository(items: [.failure(ArchiveError.offline), .success(universities)])
        let viewModel = BrowseViewModel(path: .root, repository: repository)
        await viewModel.load()

        await viewModel.refresh()

        #expect(viewModel.state == .loaded(universities))
    }

    // MARK: - Searching

    @Test("Search ignores case, Turkish dots, diacritics and surrounding spaces", arguments: SearchCase.all)
    func search(_ testCase: SearchCase) async {
        let viewModel = BrowseViewModel(path: .root, repository: StubArchiveRepository(items: [.success(universities)]))
        await viewModel.load()

        viewModel.searchText = testCase.query

        #expect(viewModel.visibleItems.map(\.name) == testCase.expectedNames(in: universities.map(\.name)))
    }

    @Test("Search keeps the list's order")
    func searchKeepsOrder() async {
        let viewModel = BrowseViewModel(path: .root, repository: StubArchiveRepository(items: [.success(universities)]))
        await viewModel.load()

        viewModel.searchText = "ünİversİtesİ"

        #expect(viewModel.visibleItems == universities)
    }

    @Test("Nothing is visible before the entries load, even while searching")
    func searchBeforeLoad() {
        let viewModel = BrowseViewModel(path: .root, repository: StubArchiveRepository(items: [.success(universities)]))

        viewModel.searchText = "kocaeli"

        #expect(viewModel.visibleItems.isEmpty)
    }

    @Test("Search applies to refreshed entries")
    func searchAfterRefresh() async {
        let added = Fixture.universities(["KOCAELİ SAĞLIK VE TEKNOLOJİ ÜNİVERSİTESİ"])
        let repository = StubArchiveRepository(items: [.success(universities), .success(universities + added)])
        let viewModel = BrowseViewModel(path: .root, repository: repository)
        await viewModel.load()
        viewModel.searchText = "kocaeli"

        await viewModel.refresh()

        #expect(viewModel.visibleItems.map(\.name) == ["KOCAELİ ÜNİVERSİTESİ", "KOCAELİ SAĞLIK VE TEKNOLOJİ ÜNİVERSİTESİ"])
    }
}

// MARK: - Cases

/// A search query and the university names it must match (`nil` means all of them).
nonisolated struct SearchCase: Sendable, CustomTestStringConvertible {
    let query: String
    let matches: [String]?

    var testDescription: String {
        "\"\(query)\""
    }

    func expectedNames(in names: [String]) -> [String] {
        matches ?? names
    }

    static let all: [SearchCase] = [
        SearchCase(query: "kocaeli", matches: ["KOCAELİ ÜNİVERSİTESİ"]),
        SearchCase(query: "KOCAELI", matches: ["KOCAELİ ÜNİVERSİTESİ"]),
        SearchCase(query: "Kocaeli Üniversitesi", matches: ["KOCAELİ ÜNİVERSİTESİ"]),
        SearchCase(query: "  kocaeli\n", matches: ["KOCAELİ ÜNİVERSİTESİ"]),
        SearchCase(query: "dumlupinar", matches: ["KÜTAHYA DUMLUPINAR ÜNİVERSİTESİ"]),
        SearchCase(query: "kutahya", matches: ["KÜTAHYA DUMLUPINAR ÜNİVERSİTESİ"]),
        SearchCase(query: "istanbul", matches: ["İSTANBUL ÜNİVERSİTESİ"]),
        SearchCase(query: "ıstanbul", matches: ["İSTANBUL ÜNİVERSİTESİ"]),
        SearchCase(query: "igdir", matches: ["IĞDIR ÜNİVERSİTESİ"]),
        SearchCase(query: "Iğdır", matches: ["IĞDIR ÜNİVERSİTESİ"]),
        SearchCase(query: "universitesi", matches: nil),
        SearchCase(query: "", matches: nil),
        SearchCase(query: "   ", matches: nil),
        SearchCase(query: "ankara", matches: []),
    ]
}

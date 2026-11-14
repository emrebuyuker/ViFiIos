import Foundation
import Testing
@testable import ViFi

@Suite("PracticeSetupViewModel", .timeLimit(.minutes(1)))
struct PracticeSetupViewModelTests {
    private let index = PracticeFixture.index(types: [
        .final: ["tr": 40, "u-bozok": 12, "c-top1": 3],
        .vize: ["tr": 1],
        .araSinav: ["u-bozok": 2, "tr": 6],
        .tekDers: ["tr": 4],
    ])

    private func makeViewModel(universityId: String? = "bozok") -> PracticeSetupViewModel {
        PracticeSetupViewModel(index: index, courseId: "top1", universityId: universityId)
    }

    @Test("Types are listed in the display order with their largest scope's count")
    func typeRows() {
        let rows = makeViewModel().typeRows

        #expect(rows.map(\.type) == [.vize, .araSinav, .final, .tekDers])
        #expect(rows.map(\.count) == [1, 6, 40, 4])
    }

    @Test("Every scope that holds questions is listed with its count, even a single question (P4)")
    func scopeRows() {
        let viewModel = makeViewModel()

        #expect(viewModel.scopeRows(for: .final).map(\.scope) == [.course, .university, .turkey])
        #expect(viewModel.scopeRows(for: .final).map(\.count) == [3, 12, 40])
        #expect(viewModel.scopeRows(for: .vize).map(\.scope) == [.turkey])
        #expect(viewModel.scopeRows(for: .vize).map(\.count) == [1])
    }

    @Test("Without a known university the \"Üniversitem\" scope is hidden")
    func universityHiddenWithoutProfile() {
        for universityId in [nil, ""] as [String?] {
            let viewModel = makeViewModel(universityId: universityId)

            #expect(viewModel.universityId == nil)
            #expect(viewModel.scopeRows(for: .final).map(\.scope) == [.course, .turkey])
            #expect(viewModel.scopeRows(for: .araSinav).map(\.scope) == [.turkey])
        }
    }

    @Test("A scope whose pool is empty is not offered")
    func emptyScopeHidden() {
        let viewModel = PracticeSetupViewModel(
            index: PracticeFixture.index(types: [.final: ["tr": 5]]), courseId: "top1", universityId: "unknown-uni"
        )

        #expect(viewModel.scopeRows(for: .final).map(\.scope) == [.turkey])
    }

    @Test("The selection carries the subject, the ids and the pool count")
    func selection() {
        let selection = makeViewModel().selection(type: .final, scope: .university)

        #expect(selection == PracticeSelection(
            subjectId: "topoloji-1", examType: .final, scope: .university, courseId: "top1",
            universityId: "bozok", poolCount: 12
        ))
    }
}

@Suite("PracticeEntryViewModel", .timeLimit(.minutes(1)))
struct PracticeEntryViewModelTests {
    private let course = ArchivePath(components: ["u", "f", "d", "c1"])

    private func makeViewModel(
        subjectId: String?, reader: StubPracticeIndexReader, path: ArchivePath? = nil
    ) -> PracticeEntryViewModel {
        PracticeEntryViewModel(
            path: path ?? course,
            repository: SubjectRepository(subjectId: subjectId),
            reader: reader
        )
    }

    @Test("A course with a subject and questions shows the entry, reading the index once")
    func available() async {
        let reader = StubPracticeIndexReader()
        reader.indexes["s1"] = PracticeFixture.index(types: [.vize: ["tr": 1]])
        let viewModel = makeViewModel(subjectId: "s1", reader: reader)

        await viewModel.load()
        await viewModel.load()

        #expect(viewModel.index?.hasPracticeQuestions == true)
        #expect(viewModel.courseId == "c1")
        #expect(reader.reads == ["s1"])
    }

    @Test("No subject, no index or a failing read hides the entry")
    func hidden() async {
        let noSubject = StubPracticeIndexReader()
        let noIndex = StubPracticeIndexReader()
        let failing = StubPracticeIndexReader()
        failing.failure = .offline

        let first = makeViewModel(subjectId: nil, reader: noSubject)
        let second = makeViewModel(subjectId: "s1", reader: noIndex)
        let third = makeViewModel(subjectId: "s1", reader: failing)
        for viewModel in [first, second, third] { await viewModel.load() }

        #expect(first.index == nil && second.index == nil && third.index == nil)
        #expect(noSubject.reads.isEmpty)
    }

    @Test("Only a course reads anything")
    func onlyCourses() async {
        let reader = StubPracticeIndexReader()
        let viewModel = makeViewModel(subjectId: "s1", reader: reader, path: ArchivePath(components: ["u", "f"]))

        await viewModel.load()

        #expect(viewModel.index == nil)
        #expect(reader.reads.isEmpty)
    }

    @Test("The caching reader reads a subject once and remembers an absent index, but not a failure")
    func caching() async throws {
        let base = StubPracticeIndexReader()
        base.indexes["s1"] = PracticeFixture.index(types: [.vize: ["tr": 1]])
        let cache = CachingPracticeIndexReader(base: base)

        _ = try await cache.index(subjectId: "s1")
        _ = try await cache.index(subjectId: "s1")
        #expect(try await cache.index(subjectId: "none") == nil)
        #expect(try await cache.index(subjectId: "none") == nil)
        #expect(base.reads == ["s1", "none"])

        base.failure = .offline
        await #expect(throws: PracticeError.offline) { _ = try await cache.index(subjectId: "later") }
        base.failure = nil
        _ = try await cache.index(subjectId: "later")
        #expect(base.reads == ["s1", "none", "later", "later"])
    }
}

/// An archive that only knows one course's subject.
private final class SubjectRepository: ArchiveRepository {
    let subjectId: String?

    init(subjectId: String?) {
        self.subjectId = subjectId
    }

    func items(at path: ArchivePath) async throws -> [ArchiveItem] { [] }
    func document(at path: ArchivePath) async throws -> ExamDocument { throw ArchiveError.notFound }
    func subjectId(forCourse path: ArchivePath) async -> String? { subjectId }
}

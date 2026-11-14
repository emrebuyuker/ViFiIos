import Foundation
import Testing
@testable import ViFi

/// An `ExamConversionServicing`-style double for the subject mapping: scripted subjects, recorded actions. Actions
/// do not change the scripted list (the server would; tests script the next `subjects()` answer instead).
final class StubSubjectMappingService: SubjectMappingServicing {
    enum Call: Equatable {
        case setCourseSubject(courseId: String, target: SubjectTarget)
        case rename(id: String, name: String)
        case merge(id: String, into: String)
    }

    var subjectList: [AdminSubject] = []
    /// Answers served (first in, first out) before `subjectList`, to script a list that changes after an action.
    var responses: [[AdminSubject]] = []
    var error: (any Error)?
    /// Fails only the actions, not the listing.
    var actionError: (any Error)?
    private(set) var calls: [Call] = []
    private(set) var listCount = 0

    func subjects() async throws -> [AdminSubject] {
        listCount += 1
        if let error { throw error }
        return responses.isEmpty ? subjectList : responses.removeFirst()
    }

    func setCourseSubject(courseId: String, to target: SubjectTarget) async throws {
        calls.append(.setCourseSubject(courseId: courseId, target: target))
        if let actionError { throw actionError }
    }

    func renameSubject(id: String, to name: String) async throws {
        calls.append(.rename(id: id, name: name))
        if let actionError { throw actionError }
    }

    func mergeSubject(id: String, into targetId: String) async throws {
        calls.append(.merge(id: id, into: targetId))
        if let actionError { throw actionError }
    }
}

enum SubjectFixture {
    static func course(_ id: String, name: String = "Ders", university: String = "ege", questions: Int = 5) -> SubjectCourse {
        SubjectCourse(
            id: id, name: name, universityId: university, universityName: university.capitalized,
            facultyName: "Mühendislik", departmentName: "Bilgisayar", questionCount: questions
        )
    }

    static func subject(_ id: String, name: String? = nil, courses: [SubjectCourse] = []) -> AdminSubject {
        AdminSubject(id: id, name: name ?? id.capitalized, aliases: [id], courses: courses)
    }
}

@MainActor
@Suite("SubjectMappingViewModel")
struct SubjectMappingViewModelTests {
    private let algorithms = SubjectFixture.subject("algoritmalar", name: "Algoritmalar", courses: [
        SubjectFixture.course("c1", name: "Algoritmalar", university: "ege", questions: 10),
    ])
    private let algorithm = SubjectFixture.subject("algoritma", name: "Algoritma", courses: [
        SubjectFixture.course("c2", name: "Algoritma", university: "itu", questions: 4),
    ])
    private let physics = SubjectFixture.subject("fizik", name: "Fizik", courses: [
        SubjectFixture.course("c3", name: "Fizik", university: "ege"), SubjectFixture.course("c4", name: "Fizik", university: "itu"),
    ])

    private func makeViewModel(_ service: StubSubjectMappingService) -> SubjectMappingViewModel {
        service.subjectList = [algorithms, algorithm, physics]
        return SubjectMappingViewModel(service: service)
    }

    @Test("Loading shows the subjects and the possible matches of single-university subjects")
    func loads() async {
        let service = StubSubjectMappingService()
        let viewModel = makeViewModel(service)

        await viewModel.loadIfNeeded()
        await viewModel.loadIfNeeded()

        #expect(viewModel.state.value?.map(\.id) == ["algoritmalar", "algoritma", "fizik"])
        #expect(service.listCount == 1)
        #expect(viewModel.possibleMatch(for: "algoritma")?.id == "algoritmalar")
        #expect(viewModel.possibleMatch(for: "algoritmalar")?.id == "algoritma")
        #expect(viewModel.possibleMatch(for: "fizik") == nil)
    }

    @Test("A failed load shows the message; refresh recovers")
    func loadFailure() async {
        let service = StubSubjectMappingService()
        service.error = ExamConversionError.offline
        let viewModel = makeViewModel(service)

        await viewModel.loadIfNeeded()
        #expect(viewModel.state == .failed(message: ExamConversionError.offline.userMessage))

        service.error = nil
        await viewModel.refresh()
        #expect(viewModel.state.value?.count == 3)
    }

    @Test("Search matches subject and course names, ignoring case and diacritics")
    func search() async {
        let service = StubSubjectMappingService()
        service.subjectList = [algorithms, SubjectFixture.subject("veri", name: "Veri Yapıları", courses: [
            SubjectFixture.course("c9", name: "Çizge Kuramı"),
        ])]
        let viewModel = SubjectMappingViewModel(service: service)
        await viewModel.loadIfNeeded()

        viewModel.searchText = "yapilari"
        #expect(viewModel.filteredSubjects.map(\.id) == ["veri"])
        viewModel.searchText = "CIZGE"
        #expect(viewModel.filteredSubjects.map(\.id) == ["veri"])
        viewModel.searchText = "  "
        #expect(viewModel.filteredSubjects.count == 2)
        viewModel.searchText = "yok"
        #expect(viewModel.filteredSubjects.isEmpty)
    }

    @Test("Changing a course's subject calls the service and reloads the list")
    func changeCourse() async throws {
        let service = StubSubjectMappingService()
        let viewModel = makeViewModel(service)
        await viewModel.loadIfNeeded()
        let moved = SubjectFixture.subject("algoritmalar", name: "Algoritmalar", courses: algorithms.courses + algorithm.courses)
        service.responses = [[moved, physics]]

        let done = await viewModel.setCourseSubject(algorithm.courses[0], to: .existing(id: "algoritmalar"))

        #expect(done)
        #expect(service.calls == [.setCourseSubject(courseId: "c2", target: .existing(id: "algoritmalar"))])
        #expect(viewModel.state.value?.map(\.id) == ["algoritmalar", "fizik"])
        #expect(viewModel.subject(id: "algoritma") == nil)
    }

    @Test("A new subject name is passed through")
    func changeCourseToNewSubject() async {
        let service = StubSubjectMappingService()
        let viewModel = makeViewModel(service)
        await viewModel.loadIfNeeded()

        _ = await viewModel.setCourseSubject(physics.courses[0], to: .new(name: "Genel Fizik"))

        #expect(service.calls == [.setCourseSubject(courseId: "c3", target: .new(name: "Genel Fizik"))])
    }

    @Test("Rename trims the name and ignores blank or unchanged ones")
    func rename() async {
        let service = StubSubjectMappingService()
        let viewModel = makeViewModel(service)
        await viewModel.loadIfNeeded()

        #expect(await viewModel.rename(physics, to: "  Genel Fizik "))
        #expect(await viewModel.rename(physics, to: "   ") == false)
        #expect(await viewModel.rename(physics, to: "Fizik") == false)

        #expect(service.calls == [.rename(id: "fizik", name: "Genel Fizik")])
    }

    @Test("Merge calls the service, reloads, and refuses merging a subject into itself")
    func merge() async {
        let service = StubSubjectMappingService()
        let viewModel = makeViewModel(service)
        await viewModel.loadIfNeeded()
        service.responses = [[SubjectFixture.subject("algoritmalar", courses: algorithms.courses + algorithm.courses), physics]]

        #expect(await viewModel.merge(algorithms, into: algorithms) == false)
        #expect(await viewModel.merge(algorithm, into: algorithms))

        #expect(service.calls == [.merge(id: "algoritma", into: "algoritmalar")])
        #expect(viewModel.subject(id: "algoritma") == nil)
        #expect(viewModel.possibleMatches.isEmpty)
    }

    @Test("A failed action keeps the list, shows the error, and does not reload")
    func actionFailure() async {
        let service = StubSubjectMappingService()
        let viewModel = makeViewModel(service)
        await viewModel.loadIfNeeded()
        service.actionError = ExamConversionError.permissionDenied

        let done = await viewModel.merge(algorithm, into: algorithms)

        #expect(done == false)
        #expect(viewModel.actionError == ExamConversionError.permissionDenied.userMessage)
        #expect(viewModel.state.value?.count == 3)
        #expect(service.listCount == 1)
        #expect(viewModel.isWorking == false)

        viewModel.clearActionError()
        #expect(viewModel.actionError == nil)
    }

    @Test("A reload failure after a successful action keeps the old list and reports the error")
    func reloadFailureAfterAction() async {
        let service = StubSubjectMappingService()
        let viewModel = makeViewModel(service)
        await viewModel.loadIfNeeded()
        service.error = ExamConversionError.offline

        let done = await viewModel.rename(physics, to: "Genel Fizik")

        #expect(done)
        #expect(viewModel.state.value?.count == 3)
        #expect(viewModel.actionError == ExamConversionError.offline.userMessage)
    }
}

@Suite("SubjectNameSimilarity")
struct SubjectNameSimilarityTests {
    @Test("Names are reduced to letters, folded Turkish letters and a trailing number")
    func keys() {
        #expect(SubjectNameSimilarity.key(for: "Veri Yapıları") == .init(base: "veriyapilari", number: ""))
        #expect(SubjectNameSimilarity.key(for: "FİZİK II") == .init(base: "fizik", number: "2"))
        #expect(SubjectNameSimilarity.key(for: "Calculus 1") == .init(base: "calculus", number: "1"))
        #expect(SubjectNameSimilarity.key(for: "I") == .init(base: "i", number: ""))
        #expect(SubjectNameSimilarity.key(for: "Matematik-I") == .init(base: "matematik", number: "1"))
    }

    @Test("Equal, prefix and near-equal names are close", arguments: [
        ("Algoritmalar", "Algoritma"), ("Fizik 1", "Fizik I"), ("Diferansiyel Denklemler", "Diferansiyel Denklem"),
        ("Veri Yapıları", "VERİ YAPILARI"), ("Lineer Cebir", "Lineer Cebr"),
    ])
    func close(pair: (String, String)) {
        #expect(SubjectNameSimilarity.areClose(pair.0, pair.1))
    }

    @Test("Different numbers, unrelated and very short names are not close", arguments: [
        ("Fizik 1", "Fizik 2"), ("Fizik I", "Fizik II"), ("Algoritmalar", "Veri Yapıları"), ("Kimya", "Kimyo"), ("", "Fizik"),
    ])
    func notClose(pair: (String, String)) {
        #expect(SubjectNameSimilarity.areClose(pair.0, pair.1) == false)
    }

    @Test("Only single-university subjects are flagged, with the biggest close subject")
    func possibleMatches() {
        let single = SubjectFixture.subject("algoritma", courses: [SubjectFixture.course("a", university: "ege")])
        let small = SubjectFixture.subject("algoritmalar", courses: [SubjectFixture.course("b", university: "itu")])
        let big = SubjectFixture.subject("algoritmalar-2", name: "Algoritmalar", courses: [
            SubjectFixture.course("c", university: "odtu"), SubjectFixture.course("d", university: "ege"),
        ])
        let unrelated = SubjectFixture.subject("fizik", courses: [SubjectFixture.course("e", university: "ege")])

        let matches = SubjectNameSimilarity.possibleMatches(in: [single, small, big, unrelated])

        #expect(matches["algoritma"] == "algoritmalar-2")
        #expect(matches["algoritmalar"] == "algoritmalar-2")
        #expect(matches["algoritmalar-2"] == nil, "two universities: already a country-wide subject")
        #expect(matches["fizik"] == nil)
    }

    @Test("A subject without courses is never flagged")
    func emptySubject() {
        let empty = SubjectFixture.subject("algoritma")
        let other = SubjectFixture.subject("algoritmalar", courses: [SubjectFixture.course("a")])
        #expect(SubjectNameSimilarity.possibleMatches(in: [empty, other])["algoritma"] == nil)
        #expect(SubjectNameSimilarity.possibleMatches(in: [empty, other])["algoritmalar"] == "algoritma")
    }
}

@Suite("SubjectMappingCalls")
struct SubjectMappingCallsTests {
    @Test("Callable names and payloads match the server contract")
    func contract() {
        #expect(SubjectMappingCalls.Name.list == "listSubjects")
        #expect(SubjectMappingCalls.Name.setCourseSubject == "setCourseSubject")
        #expect(SubjectMappingCalls.Name.rename == "renameSubject")
        #expect(SubjectMappingCalls.Name.merge == "mergeSubjects")
        #expect(SubjectMappingCalls.setCourseSubject(courseId: "c", to: .existing(id: "s")) as NSDictionary == ["courseId": "c", "subjectId": "s"])
        #expect(SubjectMappingCalls.setCourseSubject(courseId: "c", to: .new(name: "N")) as NSDictionary == ["courseId": "c", "newSubjectName": "N"])
        #expect(SubjectMappingCalls.rename(id: "s", to: "N") as NSDictionary == ["subjectId": "s", "name": "N"])
        #expect(SubjectMappingCalls.merge(id: "a", into: "b") as NSDictionary == ["fromSubjectId": "a", "intoSubjectId": "b"])
    }

    @Test("The list response is parsed; entries without an id are dropped")
    func parsing() {
        let data: [String: Any] = ["subjects": [
            [
                "id": "algoritmalar", "name": "Algoritmalar", "aliases": ["algoritmalar"], "courseCount": 1, "questionCount": 7,
                "courses": [[
                    "id": "c1", "name": "Algoritmalar", "universityId": "ege", "universityName": "Ege Üniversitesi",
                    "facultyName": "Mühendislik", "departmentName": "Bilgisayar", "questionCount": 7,
                ], ["name": "no id"]],
            ],
            ["name": "no id either"],
            ["id": "bos"],
        ]]

        let subjects = SubjectMappingCalls.subjects(from: data)

        #expect(subjects.map(\.id) == ["algoritmalar", "bos"])
        #expect(subjects[0].courses.map(\.id) == ["c1"])
        #expect(subjects[0].questionCount == 7)
        #expect(subjects[0].courses[0].place == "Mühendislik · Bilgisayar")
        #expect(subjects[1].name == "bos")
        #expect(SubjectMappingCalls.subjects(from: nil).isEmpty)
    }
}

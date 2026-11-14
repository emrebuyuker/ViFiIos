#if DEBUG
import Foundation

/// An in-memory subject mapping for previews, UI tests and demos (`-ViFiMockData`): five subjects, two of which
/// ("Algoritmalar" / "Algoritma", one university each) look like the same course. Actions update the list like the
/// server would.
final class MockSubjectMappingService: SubjectMappingServicing {
    private var current: [AdminSubject]
    private let latency: Duration

    init(subjects: [AdminSubject] = MockSubjectMappingService.samples, latency: Duration = .milliseconds(200)) {
        current = subjects
        self.latency = latency
    }

    static let samples: [AdminSubject] = [
        AdminSubject(id: "algoritmalar", name: "Algoritmalar", aliases: ["algoritmalar"], courses: [
            course("c-algo-bogazici", "Algoritmalar", "bogazici", "Boğaziçi Üniversitesi", 24),
        ]),
        AdminSubject(id: "algoritma", name: "Algoritma", aliases: ["algoritma"], courses: [
            course("c-algo-ege", "Algoritma", "ege", "Ege Üniversitesi", 12),
        ]),
        AdminSubject(id: "fizik-1", name: "Fizik 1", aliases: ["fizik-1", "fizik-i"], courses: [
            course("c-fizik-bogazici", "Fizik I", "bogazici", "Boğaziçi Üniversitesi", 30),
            course("c-fizik-ege", "Fizik 1", "ege", "Ege Üniversitesi", 18),
        ]),
        AdminSubject(id: "fizik-2", name: "Fizik 2", aliases: ["fizik-2"], courses: [
            course("c-fizik2-ege", "Fizik 2", "ege", "Ege Üniversitesi", 9),
        ]),
        AdminSubject(id: "veri-yapilari", name: "Veri Yapıları", aliases: ["veri-yapilari"], courses: [
            course("c-veri-ege", "Veri Yapıları", "ege", "Ege Üniversitesi", 15),
            course("c-veri-itu", "Veri Yapıları ve Algoritmalar", "itu", "İstanbul Teknik Üniversitesi", 6),
        ]),
    ]

    private static func course(_ id: String, _ name: String, _ universityId: String, _ university: String, _ questions: Int) -> SubjectCourse {
        SubjectCourse(
            id: id, name: name, universityId: universityId, universityName: university,
            facultyName: "Mühendislik Fakültesi", departmentName: "Bilgisayar Mühendisliği", questionCount: questions
        )
    }

    func subjects() async throws -> [AdminSubject] {
        try await Task.sleep(for: latency)
        return current.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    func setCourseSubject(courseId: String, to target: SubjectTarget) async throws {
        try await Task.sleep(for: latency)
        guard let moving = current.flatMap(\.courses).first(where: { $0.id == courseId }) else {
            throw ExamConversionError.notFound
        }
        let targetId: String
        switch target {
        case let .existing(id):
            guard current.contains(where: { $0.id == id }) else { throw ExamConversionError.notFound }
            targetId = id
        case let .new(name):
            targetId = name.lowercased().replacing(" ", with: "-")
            if !current.contains(where: { $0.id == targetId }) {
                current.append(AdminSubject(id: targetId, name: name, aliases: [targetId], courses: []))
            }
        }
        current = current.map { subject in
            var courses = subject.courses.filter { $0.id != courseId }
            if subject.id == targetId { courses.append(moving) }
            return AdminSubject(id: subject.id, name: subject.name, aliases: subject.aliases, courses: courses)
        }
    }

    func renameSubject(id: String, to name: String) async throws {
        try await Task.sleep(for: latency)
        guard current.contains(where: { $0.id == id }) else { throw ExamConversionError.notFound }
        current = current.map { $0.id == id ? AdminSubject(id: id, name: name, aliases: $0.aliases, courses: $0.courses) : $0 }
    }

    func mergeSubject(id: String, into targetId: String) async throws {
        try await Task.sleep(for: latency)
        guard let from = current.first(where: { $0.id == id }), let into = current.first(where: { $0.id == targetId }) else {
            throw ExamConversionError.notFound
        }
        let merged = AdminSubject(
            id: into.id, name: into.name, aliases: into.aliases + from.aliases, courses: into.courses + from.courses
        )
        current = current.filter { $0.id != id }.map { $0.id == targetId ? merged : $0 }
    }
}
#endif

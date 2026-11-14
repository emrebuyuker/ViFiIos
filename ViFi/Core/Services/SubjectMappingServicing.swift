import Foundation

/// Admin-only subject mapping (4.2.0 practice mode, P5): review which country-wide course identity each course
/// belongs to and fix it. Calls go to admin-gated callables (`conversions/subjectsAdmin.js`), so they fail for
/// non-admins. Debug sample: `MockSubjectMappingService`; test double: `StubSubjectMappingService`.
protocol SubjectMappingServicing: AnyObject {
    /// Every subject with its courses and question counts.
    func subjects() async throws -> [AdminSubject]

    /// Points a course at an existing subject or a new one; its published questions and practice pools move with it.
    func setCourseSubject(courseId: String, to target: SubjectTarget) async throws

    /// Renames a subject (its id never changes).
    func renameSubject(id: String, to name: String) async throws

    /// Moves every course of `id` into `targetId` and deletes `id`.
    func mergeSubject(id: String, into targetId: String) async throws
}

/// The subject mapping where none is wired: every call fails, so the admin screen shows an error.
final class UnavailableSubjectMappingService: SubjectMappingServicing {
    private let failure = ExamConversionError.unknown(message: String(localized: "Ders eşleme servisi kullanılamıyor."))

    func subjects() async throws -> [AdminSubject] { throw failure }
    func setCourseSubject(courseId: String, to target: SubjectTarget) async throws { throw failure }
    func renameSubject(id: String, to name: String) async throws { throw failure }
    func mergeSubject(id: String, into targetId: String) async throws { throw failure }
}

/// Callable names, request payloads and the response parser of the subject-mapping callables.
nonisolated enum SubjectMappingCalls {
    enum Name {
        static let list = "listSubjects"
        static let setCourseSubject = "setCourseSubject"
        static let rename = "renameSubject"
        static let merge = "mergeSubjects"
    }

    static func setCourseSubject(courseId: String, to target: SubjectTarget) -> [String: Any] {
        switch target {
        case let .existing(id): ["courseId": courseId, "subjectId": id]
        case let .new(name): ["courseId": courseId, "newSubjectName": name]
        }
    }

    static func rename(id: String, to name: String) -> [String: Any] {
        ["subjectId": id, "name": name]
    }

    static func merge(id: String, into targetId: String) -> [String: Any] {
        ["fromSubjectId": id, "intoSubjectId": targetId]
    }

    /// `{ subjects: [{ id, name, aliases, courses: [...] }] }`; entries without an id are dropped.
    static func subjects(from data: Any?) -> [AdminSubject] {
        let entries = (data as? [String: Any])?["subjects"] as? [[String: Any]] ?? []
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
            let courses = (entry["courses"] as? [[String: Any]] ?? []).compactMap(course(from:))
            return AdminSubject(
                id: id,
                name: (entry["name"] as? String) ?? id,
                aliases: (entry["aliases"] as? [Any])?.compactMap { $0 as? String } ?? [],
                courses: courses
            )
        }
    }

    private static func course(from entry: [String: Any]) -> SubjectCourse? {
        guard let id = entry["id"] as? String, !id.isEmpty else { return nil }
        return SubjectCourse(
            id: id,
            name: (entry["name"] as? String) ?? id,
            universityId: entry["universityId"] as? String ?? "",
            universityName: entry["universityName"] as? String ?? "",
            facultyName: entry["facultyName"] as? String ?? "",
            departmentName: entry["departmentName"] as? String ?? "",
            questionCount: max(0, (entry["questionCount"] as? NSNumber)?.intValue ?? 0)
        )
    }
}

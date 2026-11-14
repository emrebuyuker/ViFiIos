@preconcurrency import FirebaseFunctions
import Foundation

/// The admin subject mapping on Firebase: admin-gated callables in `europe-west1` (`listSubjects`,
/// `setCourseSubject`, `renameSubject`, `mergeSubjects`). Failures map to `ExamConversionError`, like the other
/// admin conversion calls.
final class FirebaseSubjectMappingService: SubjectMappingServicing {
    private static let region = "europe-west1"

    private let functions: Functions

    init(functions: Functions = Functions.functions(region: region)) {
        self.functions = functions
    }

    func subjects() async throws -> [AdminSubject] {
        SubjectMappingCalls.subjects(from: try await call(SubjectMappingCalls.Name.list, [:]))
    }

    func setCourseSubject(courseId: String, to target: SubjectTarget) async throws {
        _ = try await call(
            SubjectMappingCalls.Name.setCourseSubject, SubjectMappingCalls.setCourseSubject(courseId: courseId, to: target)
        )
    }

    func renameSubject(id: String, to name: String) async throws {
        _ = try await call(SubjectMappingCalls.Name.rename, SubjectMappingCalls.rename(id: id, to: name))
    }

    func mergeSubject(id: String, into targetId: String) async throws {
        _ = try await call(SubjectMappingCalls.Name.merge, SubjectMappingCalls.merge(id: id, into: targetId))
    }

    private func call(_ name: String, _ payload: sending [String: Any]) async throws -> sending Any? {
        do {
            return try await functions.httpsCallable(name).call(payload).data
        } catch {
            throw FirebaseExamConversionService.conversionError(from: error)
        }
    }
}

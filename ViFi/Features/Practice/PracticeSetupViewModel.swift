import Foundation
import Observation

/// Decides whether a course offers "Sınava gir": reads its subject, then the subject's pool index (one read, cached
/// for the session). Any failure, no subject or no questions leaves the entry hidden; it never shows an error.
@Observable
final class PracticeEntryViewModel {
    /// The subject's index once it has at least one practice question; `nil` hides the entry.
    private(set) var index: PracticePoolIndex?

    @ObservationIgnored private let path: ArchivePath
    @ObservationIgnored private let repository: any ArchiveRepository
    @ObservationIgnored private let reader: any PracticeIndexReading
    @ObservationIgnored private var hasLoaded = false

    init(path: ArchivePath, repository: any ArchiveRepository, reader: any PracticeIndexReading) {
        self.path = path
        self.repository = repository
        self.reader = reader
    }

    /// The course's id (the archive's last path component), used for the "Bu ders" scope.
    var courseId: String { path.components.last ?? "" }

    func load() async {
        guard !hasLoaded, path.level == .lesson else { return }
        guard let subjectId = await repository.subjectId(forCourse: path),
              let loaded = try? await reader.index(subjectId: subjectId) else { return }
        hasLoaded = true
        index = loaded.hasPracticeQuestions ? loaded : nil
    }
}

/// The setup's two steps: the exam type, then the scope. Pure state over the index; the views push the next step.
@Observable
final class PracticeSetupViewModel {
    struct TypeRow: Identifiable, Equatable {
        let type: ExamType
        /// The largest scope's count (Türkiye geneli includes the others).
        let count: Int
        var id: ExamType { type }
    }

    struct ScopeRow: Identifiable, Equatable {
        let scope: PracticeScope
        let count: Int
        var id: PracticeScope { scope }
    }

    let index: PracticePoolIndex
    let courseId: String
    /// The signed-in user's university id from the profile; `nil` (scope hidden) when unknown.
    let universityId: String?

    init(index: PracticePoolIndex, courseId: String, universityId: String?) {
        self.index = index
        self.courseId = courseId
        self.universityId = universityId.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The practice types the subject has questions for, in the setup's display order.
    var typeRows: [TypeRow] {
        ExamType.practiceDisplayOrder.compactMap { type in
            let largest = PracticeScope.allCases
                .map { count(type, $0) }
                .max() ?? 0
            return largest > 0 ? TypeRow(type: type, count: largest) : nil
        }
    }

    /// The scopes of `type` that hold questions, each with its count (one question is enough, P4). "Üniversitem" is
    /// left out without a known university.
    func scopeRows(for type: ExamType) -> [ScopeRow] {
        PracticeScope.allCases.compactMap { scope in
            let count = count(type, scope)
            return count > 0 ? ScopeRow(scope: scope, count: count) : nil
        }
    }

    func selection(type: ExamType, scope: PracticeScope) -> PracticeSelection {
        PracticeSelection(
            subjectId: index.subjectId,
            examType: type,
            scope: scope,
            courseId: courseId,
            universityId: universityId,
            poolCount: count(type, scope)
        )
    }

    private func count(_ type: ExamType, _ scope: PracticeScope) -> Int {
        index.count(type: type, scope: scope, courseId: courseId, universityId: universityId)
    }
}

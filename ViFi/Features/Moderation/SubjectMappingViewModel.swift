import Foundation
import Observation

/// Drives the admin subject-mapping screens (P5): the subject list with search, the "Olası eşleşme" hints, and the
/// three fixes — change a course's subject, rename a subject, merge one into another. Every fix reloads the list
/// from the server afterwards, so what is shown is what the server holds.
@Observable
final class SubjectMappingViewModel {
    private(set) var state: Loadable<[AdminSubject]> = .loading
    var searchText = ""
    private(set) var isWorking = false
    /// The last failed action, shown above the list.
    private(set) var actionError: String?
    /// Subject id → id of the subject it probably duplicates (only single-university subjects).
    private(set) var possibleMatches: [String: String] = [:]

    @ObservationIgnored private let service: any SubjectMappingServicing
    @ObservationIgnored private var hasLoaded = false

    init(service: any SubjectMappingServicing) {
        self.service = service
    }

    /// The subjects the search shows: those whose name or one of whose course names contains the text
    /// (case- and diacritic-insensitive); everything for a blank search.
    var filteredSubjects: [AdminSubject] {
        guard let subjects = state.value else { return [] }
        let query = Self.fold(searchText)
        guard !query.isEmpty else { return subjects }
        return subjects.filter { subject in
            Self.fold(subject.name).contains(query) || subject.courses.contains { Self.fold($0.name).contains(query) }
        }
    }

    func subject(id: String) -> AdminSubject? {
        state.value?.first { $0.id == id }
    }

    /// The subject `id` probably duplicates, if any.
    func possibleMatch(for id: String) -> AdminSubject? {
        possibleMatches[id].flatMap(subject(id:))
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await load()
    }

    func refresh() async {
        await load()
    }

    func clearActionError() {
        actionError = nil
    }

    /// Moves a course to another (or a new) subject; the server moves its questions and pools too.
    func setCourseSubject(_ course: SubjectCourse, to target: SubjectTarget) async -> Bool {
        await perform { try await self.service.setCourseSubject(courseId: course.id, to: target) }
    }

    func rename(_ subject: AdminSubject, to name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != subject.name else { return false }
        return await perform { try await self.service.renameSubject(id: subject.id, to: trimmed) }
    }

    /// Merges `subject` into `target`: its courses, questions and pools move, then it is deleted.
    func merge(_ subject: AdminSubject, into target: AdminSubject) async -> Bool {
        guard subject.id != target.id else { return false }
        return await perform { try await self.service.mergeSubject(id: subject.id, into: target.id) }
    }

    // MARK: - Private

    private func load() async {
        do {
            apply(try await service.subjects())
        } catch {
            if state.value == nil { state = .failed(message: error.userMessage) } else { actionError = error.userMessage }
        }
    }

    private func apply(_ subjects: [AdminSubject]) {
        possibleMatches = SubjectNameSimilarity.possibleMatches(in: subjects)
        state = .loaded(subjects)
    }

    private func perform(_ action: () async throws -> Void) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        actionError = nil
        defer { isWorking = false }
        do {
            try await action()
        } catch {
            actionError = error.userMessage
            return false
        }
        await load()
        return true
    }

    private static func fold(_ text: String) -> String {
        SubjectNameSimilarity.fold(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

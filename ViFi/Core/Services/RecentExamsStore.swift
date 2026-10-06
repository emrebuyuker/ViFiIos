import Foundation
import Observation

/// An exam the user opened, shown on the home screen.
nonisolated struct RecentExam: Codable, Hashable, Identifiable, Sendable {
    let path: ArchivePath
    let kind: ExamKind
    let openedAt: Date

    var id: ArchivePath { path }
    var title: String { path.name ?? "" }
    /// "University › Lesson", for the card subtitle.
    var subtitle: String {
        [path.components.first, path.components.dropLast().last]
            .compactMap { $0 }
            .joined(separator: " › ")
    }
}

/// Persists the most recently opened exams in `UserDefaults`.
@Observable
final class RecentExamsStore {
    static let maxCount = 10
    private static let storageKey = "recentExams.v1"

    private(set) var exams: [RecentExam] = []

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        exams = Self.load(from: defaults)
    }

    /// Moves the exam to the top of the list.
    func record(path: ArchivePath, kind: ExamKind, at date: Date = .now) {
        var updated = exams.filter { $0.path != path }
        updated.insert(RecentExam(path: path, kind: kind, openedAt: date), at: 0)
        exams = Array(updated.prefix(Self.maxCount))
        save()
    }

    func remove(_ exam: RecentExam) {
        exams.removeAll { $0.path == exam.path }
        save()
    }

    func clear() {
        exams = []
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(exams) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private static func load(from defaults: UserDefaults) -> [RecentExam] {
        guard let data = defaults.data(forKey: storageKey),
              let exams = try? JSONDecoder().decode([RecentExam].self, from: data) else { return [] }
        return exams
    }
}

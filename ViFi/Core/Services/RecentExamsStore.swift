import Foundation
import Observation
import OSLog

/// An exam the user opened, shown on the home screen.
nonisolated struct RecentExam: Codable, Hashable, Identifiable, Sendable {
    let path: ArchivePath
    let kind: ExamKind
    let openedAt: Date

    var id: ArchivePath { path }
    var title: String { path.displayName ?? "" }
    /// "University › Lesson", for the card subtitle.
    var subtitle: String {
        [path.displayNames.first, path.displayNames.dropLast().last]
            .compactMap { $0 }
            .joined(separator: " › ")
    }
}

/// Persists the most recently opened exams in `UserDefaults`.
@Observable
final class RecentExamsStore {
    static let maxCount = 10
    // Bump the version suffix on an incompatible `RecentExam` schema change: the old key is then ignored and
    // the (disposable) list simply starts empty, rather than carrying an undecodable blob around.
    private static let storageKey = "recentExams.v1"

    private(set) var exams: [RecentExam] = []

    @ObservationIgnored private let defaults: UserDefaults
    // Reused instead of allocating a coder per save/load; all access is on the main actor.
    @ObservationIgnored private let encoder = JSONEncoder()
    @ObservationIgnored private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        exams = Self.load(from: defaults, using: decoder)
    }

    /// Moves the exam to the top of the list.
    func record(path: ArchivePath, kind: ExamKind, at date: Date = .now) {
        var updated = exams.filter { $0.path != path }
        updated.insert(RecentExam(path: path, kind: kind, openedAt: date), at: 0)
        exams = Array(updated.prefix(Self.maxCount))
        save()
    }

    func remove(_ exam: RecentExam) {
        remove(path: exam.path)
    }

    /// Removes any entry for `path` (e.g. an exam that no longer exists), persisting only when something changed.
    func remove(path: ArchivePath) {
        let countBefore = exams.count
        exams.removeAll { $0.path == path }
        guard exams.count != countBefore else { return }
        save()
    }

    func clear() {
        exams = []
        save()
    }

    private func save() {
        do {
            defaults.set(try encoder.encode(exams), forKey: Self.storageKey)
        } catch {
            Logger.app.error("Saving recent exams failed: \(String(describing: error), privacy: .public)")
        }
    }

    private static func load(from defaults: UserDefaults, using decoder: JSONDecoder) -> [RecentExam] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        do {
            return try decoder.decode([RecentExam].self, from: data)
        } catch {
            // A decode failure means a corrupt or outdated blob; start empty rather than keep retrying it.
            Logger.app.notice("Discarding unreadable recent exams: \(String(describing: error), privacy: .public)")
            return []
        }
    }
}

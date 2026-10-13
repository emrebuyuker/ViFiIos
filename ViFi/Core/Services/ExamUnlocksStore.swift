import Foundation
import Observation
import OSLog

/// The signed-in user's unlocked exams, kept for the app so the archive can show lock state consistently.
///
/// `RootView` loads it for the signed-in user and resets it on sign-out; an exam just unlocked is added
/// optimistically so the UI updates without a re-read. A failed load leaves the set empty — locking more is the
/// safe default.
@Observable
final class ExamUnlocksStore {
    private(set) var unlockedIds: Set<String> = []

    @ObservationIgnored private let reader: any UnlocksReading

    init(reader: any UnlocksReading) {
        self.reader = reader
    }

    func isUnlocked(_ examId: String) -> Bool {
        unlockedIds.contains(examId)
    }

    /// Loads the user's unlocks. A failure keeps the current set (empty by default).
    func load(uid: String) async {
        do {
            unlockedIds = try await reader.unlockedExamIds(uid: uid)
        } catch is CancellationError {
            // A newer load or sign-out superseded this one.
        } catch {
            Logger.app.error("Loading unlocks failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Reflects an exam the user just unlocked, without a re-read.
    func markUnlocked(_ examId: String) {
        unlockedIds.insert(examId)
    }

    /// Clears the set on sign-out, so the next user starts from their own unlocks.
    func reset() {
        unlockedIds = []
    }
}

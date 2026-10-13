import Foundation

/// The free-exam rule and the coin cost of unlocking the rest.
///
/// Every course offers its oldest `freeCount` exams to everyone; the rest are locked until the user spends
/// coins to unlock them (one by one, forever). Exam lists arrive newest-first, so the oldest — the free ones —
/// are at the end. Pure and Firebase-free so the rule is unit-tested.
nonisolated enum ExamLock {
    /// How many of each course's oldest exams are free.
    static let freeCount = 2
    /// Coins charged to unlock one exam (kept in step with the Cloud Function's `UNLOCK_COST`).
    static let unlockCost = 100

    /// The ids of the exams that are free to open — the `freeCount` oldest in `orderedExams` (newest-first, so
    /// the oldest are the last `freeCount`).
    static func freeExamIds(orderedExams: [ArchiveItem]) -> Set<String> {
        Set(orderedExams.suffix(freeCount).compactMap { $0.path.components.last })
    }

    /// Whether `exam` can be opened: it is one of the free (oldest) exams, or the user has unlocked it. A
    /// non-exam item (or one without an id) is always accessible.
    static func isAccessible(_ exam: ArchiveItem, freeIds: Set<String>, unlockedIds: Set<String>) -> Bool {
        guard exam.level == .exam, let id = exam.path.components.last else { return true }
        return freeIds.contains(id) || unlockedIds.contains(id)
    }
}

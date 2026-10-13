import Foundation

/// Reads the set of exams a user has unlocked (`users/<uid>/unlocks/<examId>`).
protocol UnlocksReading: AnyObject {
    /// The ids of the exams `uid` has unlocked.
    func unlockedExamIds(uid: String) async throws -> Set<String>
}

import Foundation
import Observation

/// The inbox's "Sınava Git": opens a notification's exam only by the archive's lock rule (`ExamAccessResolver`).
/// Free, unlocked and subscriber exams open; a locked one gets the archive's unlock sheet first; an exam that is
/// gone (or a course that cannot be loaded) explains why instead.
///
/// Owned by `InboxView`; it decides, the view presents (the sheet, the alert) and navigates.
@Observable
final class InboxExamGate {
    /// What the view does once the unlock sheet has gone away (it cannot present or navigate while the sheet is
    /// still being dismissed).
    enum FollowUp: Equatable {
        /// The exam was unlocked: open it.
        case open(NotificationExamTarget)
        case addExam
        case paywall
    }

    /// The exam being checked; its row shows progress and further taps wait.
    private(set) var checkingExamId: String?
    /// The locked exam the unlock sheet is up for.
    var lockedExam: ArchiveItem?
    /// Why the exam could not be opened (an alert).
    var errorMessage: String?
    /// The target the unlock sheet is about.
    private(set) var lockedTarget: NotificationExamTarget?
    /// Set by the unlock sheet's outcome, run by the view when the sheet is dismissed.
    var followUp: FollowUp?

    /// Checks `target` and returns whether it may open now. `false` either presents the unlock sheet
    /// (`lockedExam`) or reports `errorMessage`; a second tap while a check is running is ignored.
    func check(
        _ target: NotificationExamTarget,
        repository: any ArchiveRepository,
        isSubscribed: Bool,
        unlockedIds: Set<String>
    ) async -> Bool {
        guard checkingExamId == nil else { return false }
        checkingExamId = target.examId
        defer { checkingExamId = nil }
        do {
            let decision = try await ExamAccessResolver.decision(
                for: target.path,
                repository: repository,
                isSubscribed: isSubscribed,
                unlockedIds: unlockedIds
            )
            switch decision {
            case .open:
                return true
            case let .locked(exam):
                lockedTarget = target
                lockedExam = exam
            case .unavailable:
                errorMessage = String(localized: "Bu sınav artık arşivde bulunmuyor.")
            }
        } catch is CancellationError {
            // The inbox went away; nothing to report.
        } catch {
            errorMessage = error.userMessage
        }
        return false
    }

    /// The unlock sheet unlocked the exam: open it once the sheet is gone.
    func unlocked() {
        followUp = lockedTarget.map(FollowUp.open)
    }

    /// The user chose to earn coins (add an exam) or to subscribe instead: close the sheet, then show that.
    func leaveForAddExam() {
        followUp = .addExam
        lockedExam = nil
    }

    func leaveForPaywall() {
        followUp = .paywall
        lockedExam = nil
    }

    /// The unlock sheet was dismissed: what to do next, if anything (consumed).
    func takeFollowUp() -> FollowUp? {
        defer {
            followUp = nil
            lockedTarget = nil
        }
        return followUp
    }
}

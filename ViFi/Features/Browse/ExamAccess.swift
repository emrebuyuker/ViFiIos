import Foundation

/// What may happen when an exam is opened from outside its course's list (a notification's "Sınava Git").
enum ExamAccessDecision: Equatable {
    /// Free, already unlocked, or the user is subscribed: open the viewer.
    case open
    /// Locked: offer the unlock sheet for this exam (as the archive does).
    case locked(ArchiveItem)
    /// No longer in the archive, or listed without files.
    case unavailable
}

/// Applies the archive's lock rule (`ExamLock`) to an exam reached by its path alone, so a notification can never
/// open a locked exam the archive would not (NOTIFICATIONS.md §8, user decision).
///
/// A subscriber, or an exam the user has already unlocked, opens straight away. Otherwise the course's exams are
/// loaded, because which exams are free depends on the whole list — exactly what `BrowseView` computes.
enum ExamAccessResolver {
    /// - Throws: The repository's error when the course cannot be loaded (e.g. offline), or `CancellationError`.
    static func decision(
        for examPath: ArchivePath,
        repository: any ArchiveRepository,
        isSubscribed: Bool,
        unlockedIds: Set<String>
    ) async throws -> ExamAccessDecision {
        guard examPath.level == .exam, let examId = examPath.components.last, let coursePath = examPath.parent else {
            return .unavailable
        }
        if isSubscribed || unlockedIds.contains(examId) {
            return .open
        }
        let exams = try await repository.items(at: coursePath)
        guard let exam = exams.first(where: { $0.path == examPath }), exam.exam != nil else {
            return .unavailable
        }
        let freeIds = ExamLock.freeExamIds(orderedExams: exams)
        let isLocked = ExamLock.isLocked(exam, freeIds: freeIds, unlockedIds: unlockedIds, isSubscribed: isSubscribed)
        return isLocked ? .locked(exam) : .open
    }
}

// MARK: - Unlocking

extension AppEnvironment {
    /// Spends coins to unlock `exam` (server-side); returns an error message on failure, `nil` on success. Shared by
    /// the archive and the inbox, so both unlock (and report it) the same way.
    func unlockExam(_ exam: ArchiveItem) async -> String? {
        guard let examId = exam.path.components.last else { return nil }
        do {
            let result = try await unlockService.unlock(examId: examId)
            unlocks.markUnlocked(examId)
            if let kind = exam.exam?.kind {
                analytics.track(.examUnlocked(kind: kind, coinsSpent: ExamLock.unlockCost, alreadyUnlocked: result.alreadyUnlocked))
            }
            return nil
        } catch {
            let reason = (error as? ExamUnlockError)?.analyticsReason ?? "unknown"
            analytics.track(.examUnlockFailed(reason: reason))
            return error.userMessage
        }
    }

    /// Buys just `exam` with money (StoreKit + server verification).
    func purchaseExamUnlock(_ exam: ArchiveItem) async -> ExamPurchaseOutcome {
        guard let examId = exam.path.components.last else { return .cancelled }
        do {
            let result = try await examPurchaseService.purchaseUnlock(examId: examId)
            switch result {
            case .success:
                unlocks.markUnlocked(examId)
                return .unlocked
            case .cancelled:
                return .cancelled
            case .pending:
                return .failed(String(localized: "Satın alma onay bekliyor; onaylanınca sınav açılır."))
            }
        } catch {
            return .failed(error.userMessage)
        }
    }

    /// Records that the unlock sheet was shown, with whether the user can currently afford the exam.
    func trackUnlockSheetShown() {
        analytics.track(.examUnlockSheetShown(canAfford: wallet.balance >= ExamLock.unlockCost))
    }
}

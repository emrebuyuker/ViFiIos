import Foundation

/// The outcome of unlocking an exam: the user's balance afterwards, and whether it was already unlocked (no
/// coins were spent).
nonisolated struct ExamUnlockResult: Equatable, Sendable {
    let balance: Int
    let alreadyUnlocked: Bool
}

/// Unlocks a locked exam by spending coins. The actual debit happens server-side (a Cloud Function), because a
/// client cannot be trusted to charge its own wallet honestly.
protocol ExamUnlockServicing: AnyObject {
    /// Unlocks `examId`, spending `ExamLock.unlockCost` coins (unless already unlocked). Throws
    /// `ExamUnlockError` — notably `.insufficientCoins` when the balance is too low.
    func unlock(examId: String) async throws -> ExamUnlockResult
}

/// Unlock failures, with Turkish messages for the UI.
nonisolated enum ExamUnlockError: LocalizedError, Equatable {
    /// The balance is below the unlock cost.
    case insufficientCoins
    case notFound
    case notSignedIn
    case offline
    case unknown(message: String)

    var errorDescription: String? {
        switch self {
        case .insufficientCoins:
            String(localized: "Bu sınavı açmak için yeterli coin yok.")
        case .notFound:
            String(localized: "Sınav bulunamadı.")
        case .notSignedIn:
            String(localized: "Oturumun sona erdi. Lütfen yeniden giriş yap.")
        case .offline:
            String(localized: "İnternet bağlantısı yok. Bağlantını kontrol edip tekrar dene.")
        case let .unknown(message):
            message
        }
    }

    /// A stable, low-cardinality reason for analytics (never the localized message).
    var analyticsReason: String {
        switch self {
        case .insufficientCoins: "insufficient_coins"
        case .notFound: "not_found"
        case .notSignedIn: "not_signed_in"
        case .offline: "offline"
        case .unknown: "unknown"
        }
    }
}

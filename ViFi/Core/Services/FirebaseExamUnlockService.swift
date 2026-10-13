@preconcurrency import FirebaseFunctions
import Foundation
import os

/// Unlocks an exam by calling the `unlockExam` Cloud Function, which debits the wallet and records the unlock
/// in one server-side transaction. The function is deployed to `europe-west1`, next to the `vifi` database.
final class FirebaseExamUnlockService: ExamUnlockServicing {
    private static let region = "europe-west1"
    private static let name = "unlockExam"

    private let functions: Functions

    init(functions: Functions = Functions.functions(region: region)) {
        self.functions = functions
    }

    func unlock(examId: String) async throws -> ExamUnlockResult {
        do {
            let response = try await functions.httpsCallable(Self.name).call(["examId": examId])
            let data = response.data as? [String: Any] ?? [:]
            let balance = (data["balance"] as? NSNumber)?.intValue ?? 0
            let alreadyUnlocked = (data["alreadyUnlocked"] as? Bool) ?? false
            return ExamUnlockResult(balance: balance, alreadyUnlocked: alreadyUnlocked)
        } catch {
            throw Self.unlockError(from: error)
        }
    }

    /// Maps a Functions/transport error to an `ExamUnlockError`, logging the original.
    nonisolated static func unlockError(from error: any Error) -> ExamUnlockError {
        let nsError = error as NSError
        if nsError.domain == FunctionsErrorDomain, let code = FunctionsErrorCode(rawValue: nsError.code) {
            switch code {
            case .failedPrecondition:
                return .insufficientCoins
            case .notFound:
                return .notFound
            case .permissionDenied, .unauthenticated:
                return .notSignedIn
            case .unavailable, .deadlineExceeded:
                return .offline
            default:
                break
            }
        }
        if nsError.domain == NSURLErrorDomain {
            return .offline
        }
        Logger.app.error("Exam unlock failed: \(String(describing: error), privacy: .public)")
        return .unknown(message: error.localizedDescription)
    }
}

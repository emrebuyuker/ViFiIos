@preconcurrency import FirebaseFunctions
import Foundation
import os
import StoreKit

/// Buys a single exam with money via StoreKit 2, then records the unlock through the `purchaseExamUnlock` Cloud
/// Function, which verifies the signed transaction with Apple before writing it.
///
/// A consumable transaction does not carry which exam it paid for, so the target exam id is persisted locally
/// just before buying and used to recover a purchase whose server call did not complete (`recoverPendingUnlock`
/// at launch). The transaction is finished only after the server records the unlock, so a dropped network never
/// loses a paid purchase.
final class StoreKitExamPurchaseService: ExamPurchaseServicing {
    private static let region = "europe-west1"
    private static let functionName = "purchaseExamUnlock"
    private static let pendingKey = "pendingExamUnlockId"

    private let functions: Functions
    private let defaults: UserDefaults

    init(functions: Functions = Functions.functions(region: region), defaults: UserDefaults = .standard) {
        self.functions = functions
        self.defaults = defaults
    }

    func purchaseUnlock(examId: String) async throws -> PurchaseResult {
        let product: Product
        do {
            guard let found = try await Product.products(for: [StoreProductID.examUnlock]).first else {
                throw SubscriptionError.productUnavailable
            }
            product = found
        } catch is SubscriptionError {
            throw SubscriptionError.productUnavailable
        } catch {
            throw SubscriptionError.storeUnavailable
        }

        // Remember the target exam before paying: a consumable transaction cannot carry it, so recovery needs it.
        pendingExamId = examId

        let result: Product.PurchaseResult
        do {
            result = try await product.purchase()
        } catch {
            Logger.app.error("Exam unlock purchase failed: \(String(describing: error), privacy: .public)")
            throw SubscriptionError.unknown(message: error.localizedDescription)
        }

        switch result {
        case let .success(verification):
            let transaction = try Self.checkVerified(verification)
            // The JWS to verify server-side lives on the VerificationResult, not the Transaction.
            try await record(examId: examId, signedTransaction: verification.jwsRepresentation)
            await transaction.finish()
            pendingExamId = nil
            return .success
        case .userCancelled:
            pendingExamId = nil
            return .cancelled
        case .pending:
            // Ask to Buy: the transaction arrives later via `recoverPendingUnlock`; keep the pending exam id.
            return .pending
        @unknown default:
            pendingExamId = nil
            return .cancelled
        }
    }

    func recoverPendingUnlock() async -> String? {
        guard let examId = pendingExamId else { return nil }
        for await result in Transaction.unfinished {
            guard case let .verified(transaction) = result,
                  transaction.productID == StoreProductID.examUnlock else { continue }
            do {
                try await record(examId: examId, signedTransaction: result.jwsRepresentation)
                await transaction.finish()
                pendingExamId = nil
                return examId
            } catch {
                // Keep the transaction unfinished and the pending id, so the next launch tries again.
                Logger.app.error("Recovering exam unlock failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        return nil
    }

    // MARK: - Helpers

    /// Sends the signed transaction to the Cloud Function, which verifies it with Apple and writes the unlock.
    private func record(examId: String, signedTransaction: String) async throws {
        do {
            _ = try await functions.httpsCallable(Self.functionName).call([
                "examId": examId,
                "signedTransaction": signedTransaction,
            ])
        } catch {
            throw Self.recordError(from: error)
        }
    }

    private var pendingExamId: String? {
        get { defaults.string(forKey: Self.pendingKey) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.pendingKey)
            } else {
                defaults.removeObject(forKey: Self.pendingKey)
            }
        }
    }

    private static func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw SubscriptionError.failedVerification
        case let .verified(value):
            return value
        }
    }

    /// Maps a Functions/transport error to a `SubscriptionError`, logging the original.
    private static func recordError(from error: any Error) -> SubscriptionError {
        let nsError = error as NSError
        if nsError.domain == FunctionsErrorDomain, let code = FunctionsErrorCode(rawValue: nsError.code) {
            switch code {
            case .failedPrecondition:
                return .failedVerification
            case .unavailable, .deadlineExceeded:
                return .storeUnavailable
            default:
                break
            }
        }
        if nsError.domain == NSURLErrorDomain {
            return .storeUnavailable
        }
        Logger.app.error("Exam unlock record failed: \(String(describing: error), privacy: .public)")
        return .unknown(message: error.localizedDescription)
    }
}

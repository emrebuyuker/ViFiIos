import Foundation

/// Buys a single exam with money (the `exam.unlock` consumable) instead of coins.
///
/// The purchase is recorded server-side: after StoreKit confirms payment, the signed transaction is sent to the
/// `purchaseExamUnlock` Cloud Function, which verifies Apple's signature and writes the unlock. The live
/// implementation is `StoreKitExamPurchaseService`; `MockExamPurchaseService` backs previews and tests.
protocol ExamPurchaseServicing: AnyObject {
    /// Buys the single-exam unlock and records it for `examId`. Returns whether it completed, was cancelled, or
    /// is pending (e.g. Ask to Buy). Throws `SubscriptionError` when the store or server fails.
    func purchaseUnlock(examId: String) async throws -> PurchaseResult

    /// Retries a purchase that completed but whose server unlock did not (a dropped network, or an Ask-to-Buy
    /// approved later). Called at launch. Returns the exam id that was unlocked, or `nil` if there was nothing
    /// to recover.
    func recoverPendingUnlock() async -> String?
}

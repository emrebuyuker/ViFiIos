import Foundation
import os
import StoreKit

/// The premium subscription, backed by StoreKit 2.
///
/// The entitlement lives in the device's App Store transactions, so it is read with
/// `Transaction.currentEntitlements` and kept live with `Transaction.updates` (renewals, expiries, refunds,
/// and purchases made on another device). Verification is done on-device via StoreKit's signed
/// `VerificationResult`; no server receipt check is needed for gating read access.
final class StoreKitSubscriptionService: SubscriptionServicing {
    func subscriptionOptions() async throws -> [SubscriptionOption] {
        let products: [Product]
        do {
            products = try await Product.products(for: StoreProductID.subscriptions)
        } catch {
            Logger.app.error("Loading subscription products failed: \(String(describing: error), privacy: .public)")
            throw SubscriptionError.storeUnavailable
        }
        guard !products.isEmpty else { throw SubscriptionError.productUnavailable }
        return products
            .compactMap(Self.option(from:))
            .sorted { $0.period == .monthly && $1.period == .yearly }
    }

    func isSubscribed() async -> Bool {
        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result else { continue }
            if StoreProductID.subscriptions.contains(transaction.productID), transaction.revocationDate == nil {
                return true
            }
        }
        return false
    }

    func statusChanges() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let task = Task {
                continuation.yield(await isSubscribed())
                // `Transaction.updates` delivers renewals, expiries, refunds and cross-device purchases for
                // the app's lifetime; re-derive the entitlement on each.
                for await _ in Transaction.updates {
                    continuation.yield(await isSubscribed())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func purchase(productID: String) async throws -> PurchaseResult {
        let products: [Product]
        do {
            products = try await Product.products(for: [productID])
        } catch {
            throw SubscriptionError.storeUnavailable
        }
        guard let product = products.first else { throw SubscriptionError.productUnavailable }

        let result: Product.PurchaseResult
        do {
            result = try await product.purchase()
        } catch {
            Logger.app.error("Subscription purchase failed: \(String(describing: error), privacy: .public)")
            throw SubscriptionError.unknown(message: error.localizedDescription)
        }

        switch result {
        case let .success(verification):
            let transaction = try Self.checkVerified(verification)
            // Finishing tells StoreKit the content was delivered; the entitlement listener updates the UI.
            await transaction.finish()
            return .success
        case .userCancelled:
            return .cancelled
        case .pending:
            return .pending
        @unknown default:
            return .cancelled
        }
    }

    func restore() async throws {
        do {
            try await AppStore.sync()
        } catch {
            Logger.app.error("Restoring purchases failed: \(String(describing: error), privacy: .public)")
            throw SubscriptionError.storeUnavailable
        }
    }

    // MARK: - Helpers

    /// Unwraps a StoreKit `VerificationResult`, throwing when the signature check fails.
    private static func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:
            throw SubscriptionError.failedVerification
        case let .verified(value):
            return value
        }
    }

    /// Flattens a StoreKit `Product` into the UI's `SubscriptionOption`; `nil` for an unrecognised id.
    private static func option(from product: Product) -> SubscriptionOption? {
        guard let period = SubscriptionPeriod.forProductID(product.id) else { return nil }
        return SubscriptionOption(
            id: product.id,
            displayName: product.displayName,
            displayPrice: product.displayPrice,
            period: period
        )
    }
}

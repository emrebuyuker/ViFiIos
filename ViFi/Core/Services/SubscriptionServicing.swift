import Foundation

/// The premium subscription, backed by the App Store.
///
/// The entitlement is read from the device's StoreKit transactions (per Apple ID), independent of Firebase
/// sign-in: an active subscription unlocks the whole archive and hides the coin economy. The live
/// implementation is `StoreKitSubscriptionService`; `MockSubscriptionService` backs previews and tests.
protocol SubscriptionServicing: AnyObject {
    /// The subscription products to show on the paywall, loaded from the store. Throws when the store cannot
    /// be reached (the paywall then shows a retry).
    func subscriptionOptions() async throws -> [SubscriptionOption]

    /// Whether the device currently holds an active (non-expired, non-revoked) subscription.
    func isSubscribed() async -> Bool

    /// Emits the current subscription state immediately, then again on every change — purchase, renewal,
    /// expiry or refund. The stream ends when the consuming task is cancelled.
    func statusChanges() -> AsyncStream<Bool>

    /// Buys the subscription with `productID`. Returns whether it completed, was cancelled, or is pending.
    func purchase(productID: String) async throws -> PurchaseResult

    /// Restores past purchases from the App Store (for a reinstall or a new device).
    func restore() async throws
}

/// Subscription failures, with Turkish messages for the UI.
nonisolated enum SubscriptionError: LocalizedError, Equatable {
    /// The store returned no product for the identifier (not yet approved, or wrong id).
    case productUnavailable
    /// The App Store could not be reached.
    case storeUnavailable
    /// A purchased transaction failed StoreKit's signature check (possible tampering).
    case failedVerification
    case unknown(message: String)

    var errorDescription: String? {
        switch self {
        case .productUnavailable:
            String(localized: "Abonelik şu anda mağazadan alınamıyor. Lütfen daha sonra tekrar dene.")
        case .storeUnavailable:
            String(localized: "App Store'a ulaşılamıyor. Bağlantını kontrol edip tekrar dene.")
        case .failedVerification:
            String(localized: "Satın alma doğrulanamadı. Lütfen tekrar dene.")
        case let .unknown(message):
            message
        }
    }

    /// A stable, low-cardinality reason for analytics (never the localized message).
    var analyticsReason: String {
        switch self {
        case .productUnavailable: "product_unavailable"
        case .storeUnavailable: "store_unavailable"
        case .failedVerification: "failed_verification"
        case .unknown: "unknown"
        }
    }
}

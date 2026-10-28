import Foundation

/// The App Store product identifiers for the premium tier, kept in one place so the StoreKit layer, the
/// paywall and the local `ViFi.storekit` test configuration agree. These must match the products created in
/// App Store Connect exactly.
nonisolated enum StoreProductID {
    /// Auto-renewable monthly subscription: unlocks the whole archive.
    static let monthly = "com.BuyukerYazilim.ViFi2.premium.monthly"
    /// Auto-renewable yearly subscription: unlocks the whole archive.
    static let yearly = "com.BuyukerYazilim.ViFi2.premium.yearly"
    /// Consumable: unlocks a single exam with money instead of coins (recorded server-side).
    static let examUnlock = "com.BuyukerYazilim.ViFi2.exam.unlock"

    /// The two subscription products, used to read the device's current entitlement and to load the paywall.
    static let subscriptions = [monthly, yearly]
}

/// The billing period of a subscription option, so the paywall can label it and sort cheapest-first.
nonisolated enum SubscriptionPeriod: Sendable, Equatable {
    case monthly
    case yearly

    /// The product id this period maps to; `nil` for an id the app does not recognise.
    static func forProductID(_ id: String) -> SubscriptionPeriod? {
        switch id {
        case StoreProductID.monthly: .monthly
        case StoreProductID.yearly: .yearly
        default: nil
        }
    }
}

/// A subscription the user can buy, flattened from a StoreKit `Product` so the paywall is Firebase- and
/// StoreKit-free (previewable with mock data, unit-testable).
nonisolated struct SubscriptionOption: Identifiable, Sendable, Equatable {
    /// The product identifier (also the `id`).
    let id: String
    /// The store's localized name, e.g. "Yıllık Premium".
    let displayName: String
    /// The store's localized price, e.g. "₺349,99".
    let displayPrice: String
    let period: SubscriptionPeriod
}

/// The outcome of a purchase attempt. A cancel or a pending (e.g. Ask to Buy) is not an error.
nonisolated enum PurchaseResult: Sendable, Equatable {
    /// The purchase completed and the transaction was verified and finished.
    case success
    /// The user dismissed the purchase sheet.
    case cancelled
    /// The purchase is awaiting external action (parental approval, SCA); it may complete later.
    case pending
}

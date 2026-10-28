import Foundation
import Observation
import os

/// The device's premium state, kept live for the whole app so the archive can drop every lock and the UI can
/// hide the coin economy while a subscription is active.
///
/// Unlike the wallet or unlocks, this is tied to the Apple ID, not the Firebase user: `RootView` starts
/// `observe()` once at launch and never resets it on sign-out. `loadOptions()` is called lazily by the paywall.
@Observable
final class SubscriptionStore {
    /// Whether an active subscription unlocks the whole archive. Starts `false` (locked is the safe default)
    /// until the first entitlement read completes.
    private(set) var isSubscribed = false
    /// The paywall's purchasable options, loaded on demand.
    private(set) var options: [SubscriptionOption] = []

    @ObservationIgnored private let service: any SubscriptionServicing

    init(service: any SubscriptionServicing) {
        self.service = service
    }

    /// Follows the subscription state for the app's lifetime; cancelled only when the app exits.
    func observe() async {
        for await active in service.statusChanges() {
            isSubscribed = active
        }
    }

    /// Loads the paywall options. A failure leaves the current list; the caller surfaces the error.
    func loadOptions() async throws {
        options = try await service.subscriptionOptions()
    }

    /// Buys `option`. On success the entitlement is re-read immediately — a transaction from a direct
    /// `purchase()` is not re-delivered through `Transaction.updates`, so `observe()` alone would not flip
    /// `isSubscribed` until the next launch.
    func purchase(_ option: SubscriptionOption) async throws -> PurchaseResult {
        let result = try await service.purchase(productID: option.id)
        if result == .success {
            isSubscribed = await service.isSubscribed()
        }
        return result
    }

    /// Restores past purchases (reinstall / new device), then re-reads the entitlement.
    func restore() async throws {
        try await service.restore()
        isSubscribed = await service.isSubscribed()
    }
}

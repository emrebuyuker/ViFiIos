import Testing
@testable import ViFi

@Suite("Subscription")
struct SubscriptionTests {
    @Test("Product ids map to their billing period")
    func periodForProductID() {
        #expect(SubscriptionPeriod.forProductID(StoreProductID.monthly) == .monthly)
        #expect(SubscriptionPeriod.forProductID(StoreProductID.yearly) == .yearly)
        #expect(SubscriptionPeriod.forProductID(StoreProductID.examUnlock) == nil)
        #expect(SubscriptionPeriod.forProductID("unknown") == nil)
    }

    @Test("The subscription ids are the monthly and yearly products")
    func subscriptionIDs() {
        #expect(StoreProductID.subscriptions == [StoreProductID.monthly, StoreProductID.yearly])
        #expect(!StoreProductID.subscriptions.contains(StoreProductID.examUnlock))
    }

    @Test("observe() follows the stream to its final state")
    func observeReflectsLatestState() async {
        let service = FakeSubscriptionService(statuses: [false, false, true])
        let store = SubscriptionStore(service: service)
        await store.observe()
        #expect(store.isSubscribed)
    }

    @Test("Loading options fills the store")
    func loadOptions() async throws {
        let options = [
            SubscriptionOption(id: StoreProductID.yearly, displayName: "Yıllık", displayPrice: "₺349", period: .yearly),
        ]
        let store = SubscriptionStore(service: FakeSubscriptionService(options: options))
        try await store.loadOptions()
        #expect(store.options == options)
    }

    @Test("A purchase delegates to the service")
    func purchaseDelegates() async throws {
        let option = SubscriptionOption(
            id: StoreProductID.monthly, displayName: "Aylık", displayPrice: "₺49", period: .monthly
        )
        let service = FakeSubscriptionService(purchaseResult: .success)
        let store = SubscriptionStore(service: service)
        let result = try await store.purchase(option)
        #expect(result == .success)
        #expect(service.purchasedProductIDs == [StoreProductID.monthly])
    }
}

/// A controllable `SubscriptionServicing` for the store tests (no StoreKit).
private final class FakeSubscriptionService: SubscriptionServicing {
    private let statuses: [Bool]
    private let options: [SubscriptionOption]
    private let purchaseResult: PurchaseResult
    private(set) var purchasedProductIDs: [String] = []

    init(
        statuses: [Bool] = [false],
        options: [SubscriptionOption] = [],
        purchaseResult: PurchaseResult = .success
    ) {
        self.statuses = statuses
        self.options = options
        self.purchaseResult = purchaseResult
    }

    func subscriptionOptions() async throws -> [SubscriptionOption] { options }

    func isSubscribed() async -> Bool { statuses.last ?? false }

    func statusChanges() -> AsyncStream<Bool> {
        let statuses = statuses
        return AsyncStream { continuation in
            for status in statuses { continuation.yield(status) }
            continuation.finish()
        }
    }

    func purchase(productID: String) async throws -> PurchaseResult {
        purchasedProductIDs.append(productID)
        return purchaseResult
    }

    func restore() async throws {}
}

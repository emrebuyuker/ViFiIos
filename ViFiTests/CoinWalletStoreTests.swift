import Foundation
import Testing
@testable import ViFi

/// A `WalletReading` that yields a fixed sequence of balances, then ends.
private final class ScriptedWalletReader: WalletReading {
    private let wallets: [CoinWallet]
    private(set) var requestedUIDs: [String] = []

    init(_ wallets: [CoinWallet]) {
        self.wallets = wallets
    }

    func walletChanges(uid: String) -> AsyncStream<CoinWallet> {
        requestedUIDs.append(uid)
        let wallets = wallets
        return AsyncStream { continuation in
            for wallet in wallets {
                continuation.yield(wallet)
            }
            continuation.finish()
        }
    }
}

@MainActor
@Suite("CoinWalletStore")
struct CoinWalletStoreTests {
    @Test("Observing applies the latest balance from the stream")
    func observeAppliesBalance() async {
        let reader = ScriptedWalletReader([
            CoinWallet(balance: 10, updatedAt: nil),
            CoinWallet(balance: 42, updatedAt: nil),
        ])
        let store = CoinWalletStore(reader: reader)

        await store.observe(uid: "user-1")

        #expect(store.balance == 42)
        #expect(reader.requestedUIDs == ["user-1"])
    }

    @Test("A fresh store starts empty")
    func startsEmpty() {
        let store = CoinWalletStore(reader: ScriptedWalletReader([]))
        #expect(store.balance == 0)
    }

    @Test("Reset clears the balance")
    func resetClears() async {
        let store = CoinWalletStore(reader: ScriptedWalletReader([CoinWallet(balance: 99, updatedAt: nil)]))
        await store.observe(uid: "user-1")
        #expect(store.balance == 99)

        store.reset()
        #expect(store.balance == 0)
    }
}

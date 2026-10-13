import Foundation
import Observation

/// The signed-in user's coin balance, kept live for the whole app so every screen can show it.
///
/// `RootView` drives it: `observe(uid:)` in a `.task(id:)` on the signed-in branch follows the wallet stream,
/// and `reset()` clears it on sign-out. Mirrors `ProfileStore` / `SessionStore`.
@Observable
final class CoinWalletStore {
    private(set) var wallet: CoinWallet = .empty

    @ObservationIgnored private let reader: any WalletReading

    init(reader: any WalletReading) {
        self.reader = reader
    }

    /// The current spendable balance.
    var balance: Int { wallet.balance }

    /// Follows the wallet for `uid` until the calling task is cancelled.
    func observe(uid: String) async {
        for await wallet in reader.walletChanges(uid: uid) {
            self.wallet = wallet
        }
    }

    /// Clears the balance on sign-out, so the next user starts blank until their own wallet loads.
    func reset() {
        wallet = .empty
    }
}

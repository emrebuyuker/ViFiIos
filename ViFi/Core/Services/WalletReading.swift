import Foundation

/// Reads a user's coin wallet from the backend with a live listener.
protocol WalletReading: AnyObject {
    /// A live stream of the wallet for `uid`: the current balance right away, then again on every change.
    /// Emits `.empty` when there is no wallet document yet or the read is rejected. The stream ends when the
    /// consuming task is cancelled.
    func walletChanges(uid: String) -> AsyncStream<CoinWallet>
}

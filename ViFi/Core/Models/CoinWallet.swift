import Foundation

/// A user's coin balance, read from `wallets/<uid>` in Cloud Firestore.
///
/// Money is server-authoritative: a client never writes its own wallet. In this serverless, admin-moderated
/// build the balance is written only by an admin's device when it approves a submission (gated by `isAdmin()`
/// in the security rules), inside a Firestore transaction that also appends the matching ledger entry. The app
/// reads the wallet live and shows the balance across the UI.
nonisolated struct CoinWallet: Equatable, Sendable {
    /// The current spendable balance; never negative.
    var balance: Int
    /// When the balance last changed (server timestamp), if known.
    var updatedAt: Date?

    /// The balance of a user who has not earned any coins yet (no wallet document).
    static let empty = CoinWallet(balance: 0, updatedAt: nil)
}

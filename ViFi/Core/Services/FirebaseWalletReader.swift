@preconcurrency import FirebaseFirestore
import Foundation
import os

/// Reads the signed-in user's coin wallet from the Cloud Firestore `wallets/<uid>` document with a live
/// snapshot listener.
///
/// Mirrors `FirebaseRewardsConfigReader`: the non-sendable `DocumentSnapshot` is parsed inside the Firestore
/// callback and never leaves it, so only the sendable `CoinWallet` crosses into the stream. The security rules
/// let the owner read their own wallet; App Check guards the read once enforcement is on.
final class FirebaseWalletReader: WalletReading {
    private static let collection = "wallets"

    private let firestore: Firestore

    init(firestore: Firestore = ViFiFirestore.shared) {
        self.firestore = firestore
    }

    func walletChanges(uid: String) -> AsyncStream<CoinWallet> {
        let document = firestore.collection(Self.collection).document(uid)
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let registration = document.addSnapshotListener { @Sendable snapshot, error in
                if let error {
                    Logger.app.error("Wallet listener failed: \(String(describing: error), privacy: .public)")
                    continuation.yield(.empty)
                    return
                }
                continuation.yield(Self.parse(snapshot?.data()))
            }
            continuation.onTermination = { @Sendable _ in
                registration.remove()
            }
        }
    }

    /// Parses the wallet document. A missing document, missing fields or a negative balance read as `.empty` /
    /// zero; Firestore integers arrive as `NSNumber`.
    nonisolated static func parse(_ data: [String: Any]?) -> CoinWallet {
        guard let data else { return .empty }
        let balance = (data["balance"] as? NSNumber)?.intValue ?? 0
        let updatedAt = (data["updatedAt"] as? Timestamp)?.dateValue()
        return CoinWallet(balance: max(0, balance), updatedAt: updatedAt)
    }
}

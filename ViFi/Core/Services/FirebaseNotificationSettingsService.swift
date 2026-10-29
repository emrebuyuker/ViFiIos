@preconcurrency import FirebaseFirestore
import Foundation
import os

/// Reads and writes the campaign-notification consent in Cloud Firestore (`vifi` database),
/// `users/{uid}/settings/notifications` (NOTIFICATIONS.md §3.5, §6).
///
/// Mirrors `FirebaseWalletReader`: the non-sendable snapshot is parsed inside the Firestore callback and never
/// leaves it. The rules let the owner read the record and write exactly `{marketing, source, version, updatedAt}`
/// (a server timestamp); nobody can delete it, and the server reads `marketing` to decide who receives campaigns.
final class FirebaseNotificationSettingsService: NotificationSettingsServicing {
    private let firestore: Firestore

    init(firestore: Firestore = ViFiFirestore.shared) {
        self.firestore = firestore
    }

    func consentChanges(uid: String) -> AsyncStream<NotificationConsentFeed> {
        let document = document(uid: uid)
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let registration = document.addSnapshotListener { @Sendable snapshot, error in
                if let error {
                    Logger.app.error("Consent listener failed: \(String(describing: error), privacy: .public)")
                    continuation.yield(.failure(.unavailable))
                    continuation.finish()
                    return
                }
                // `.estimate`: a write still pending reads with its local values, so the toggle follows the tap.
                continuation.yield(.success(Self.parse(snapshot?.data(with: .estimate))))
            }
            continuation.onTermination = { @Sendable _ in
                registration.remove()
            }
        }
    }

    func setMarketing(_ enabled: Bool, source: NotificationConsentSource, uid: String) async throws {
        try await document(uid: uid).setData(Self.fields(marketing: enabled, source: source))
    }

    private func document(uid: String) -> DocumentReference {
        firestore.collection("users").document(uid).collection("settings").document("notifications")
    }

    /// The consent in `data`, or `nil` when there is no record (or it has no boolean `marketing`).
    nonisolated static func parse(_ data: [String: Any]?) -> NotificationConsent? {
        guard let marketing = data?["marketing"] as? Bool else { return nil }
        return NotificationConsent(marketing: marketing)
    }

    /// The document body the rules accept: exactly `{marketing, source, version, updatedAt}`.
    nonisolated static func fields(marketing: Bool, source: NotificationConsentSource) -> [String: Any] {
        [
            "marketing": marketing,
            "source": source.rawValue,
            "version": NotificationConsent.currentVersion,
            "updatedAt": FieldValue.serverTimestamp(),
        ]
    }
}

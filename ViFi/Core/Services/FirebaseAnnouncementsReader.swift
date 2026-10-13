@preconcurrency import FirebaseFirestore
import Foundation
import os

/// Reads the public `announcements` collection (Cloud Firestore `vifi` database) with a live snapshot
/// listener, newest first.
///
/// Mirrors `FirebaseWalletReader`: the non-sendable `QuerySnapshot` is parsed inside the Firestore callback and
/// never leaves it, so only the sendable `[Announcement]` crosses into the stream. Rules let any signed-in user
/// read; announcements are written server-side / from the Console.
final class FirebaseAnnouncementsReader: AnnouncementsReading {
    private static let collection = "announcements"
    private static let maxCount = 50

    private let firestore: Firestore

    init(firestore: Firestore = ViFiFirestore.shared) {
        self.firestore = firestore
    }

    func announcementsChanges() -> AsyncStream<[Announcement]> {
        let query = firestore.collection(Self.collection)
            .order(by: "createdAt", descending: true)
            .limit(to: Self.maxCount)
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let registration = query.addSnapshotListener { @Sendable snapshot, error in
                if let error {
                    Logger.app.error("Announcements listener failed: \(String(describing: error), privacy: .public)")
                    continuation.yield([])
                    return
                }
                let items = (snapshot?.documents ?? []).compactMap { Self.parse(id: $0.documentID, data: $0.data()) }
                continuation.yield(items)
            }
            continuation.onTermination = { @Sendable _ in
                registration.remove()
            }
        }
    }

    /// Parses an announcement document. Requires a non-empty title; the body and date are optional.
    nonisolated static func parse(id: String, data: [String: Any]) -> Announcement? {
        let title = (data["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return nil }
        let body = (data["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let createdAt = (data["createdAt"] as? Timestamp)?.dateValue()
        return Announcement(id: id, title: title, body: body, createdAt: createdAt)
    }
}

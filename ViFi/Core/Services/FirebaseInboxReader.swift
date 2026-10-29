@preconcurrency import FirebaseFirestore
import Foundation
import os

/// Reads the in-app inbox from Cloud Firestore (`vifi` database) with live snapshot listeners: the public
/// `announcements` collection, the user's own `users/{uid}/inbox`, and the `users/{uid}/settings/inbox` read
/// marker.
///
/// Mirrors `FirebaseWalletReader`: the non-sendable snapshots are parsed inside the Firestore callback and never
/// leave it, so only sendable values cross into the streams. Documents are parsed by
/// `NotificationPayloadParser`, after the `Timestamp` values are turned into `Date`s here (the parser is free of
/// the SDK). A listener error is reported as a failure, never as an empty list.
final class FirebaseInboxReader: InboxReading {
    private static let broadcastCollection = "announcements"
    private static let broadcastLimit = 50
    private static let personalLimit = 100

    private let firestore: Firestore

    init(firestore: Firestore = ViFiFirestore.shared) {
        self.firestore = firestore
    }

    func broadcastChanges() -> AsyncStream<InboxFeed> {
        let query = firestore.collection(Self.broadcastCollection)
            .order(by: "createdAt", descending: true)
            .limit(to: Self.broadcastLimit)
        return feed(of: query, source: .broadcast)
    }

    func personalChanges(uid: String) -> AsyncStream<InboxFeed> {
        let query = firestore.collection("users").document(uid).collection("inbox")
            .order(by: "createdAt", descending: true)
            .limit(to: Self.personalLimit)
        return feed(of: query, source: .personal)
    }

    func readMarkerChanges(uid: String) -> AsyncStream<Result<Date?, InboxError>> {
        let document = readMarkerDocument(uid: uid)
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let registration = document.addSnapshotListener { @Sendable snapshot, error in
                if let error {
                    Logger.app.error("Inbox read marker listener failed: \(String(describing: error), privacy: .public)")
                    continuation.yield(.failure(.unavailable))
                    continuation.finish()
                    return
                }
                // `.estimate`: while the write of the marker is still pending its timestamp reads as the local
                // estimate instead of missing, so the unread count does not flash back after opening the inbox.
                let readAt = (snapshot?.data(with: .estimate)?["readAt"] as? Timestamp)?.dateValue()
                continuation.yield(.success(readAt))
            }
            continuation.onTermination = { @Sendable _ in
                registration.remove()
            }
        }
    }

    func markRead(uid: String) async throws {
        // The rules accept exactly `{readAt: <request time>}`.
        try await readMarkerDocument(uid: uid).setData(["readAt": FieldValue.serverTimestamp()])
    }

    private func readMarkerDocument(uid: String) -> DocumentReference {
        firestore.collection("users").document(uid).collection("settings").document("inbox")
    }

    private func feed(of query: Query, source: InboxItem.Source) -> AsyncStream<InboxFeed> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let registration = query.addSnapshotListener { @Sendable snapshot, error in
                if let error {
                    Logger.app.error("Inbox listener failed: \(String(describing: error), privacy: .public)")
                    continuation.yield(.failure(.unavailable))
                    continuation.finish()
                    return
                }
                let items = (snapshot?.documents ?? []).compactMap {
                    Self.item(id: $0.documentID, source: source, data: $0.data())
                }
                continuation.yield(.success(items))
            }
            continuation.onTermination = { @Sendable _ in
                registration.remove()
            }
        }
    }

    /// Parses an inbox document. Requires a valid id and a non-empty title; unknown values are tolerated.
    nonisolated static func item(id: String, source: InboxItem.Source, data: [String: Any]) -> InboxItem? {
        NotificationPayloadParser.inboxItem(id: id, source: source, data: firestoreDates(data))
    }

    /// `data` with its Firestore `Timestamp` values turned into `Date`s (only the top level carries dates).
    private nonisolated static func firestoreDates(_ data: [String: Any]) -> [String: Any] {
        data.mapValues { value -> Any in
            if let timestamp = value as? Timestamp {
                return timestamp.dateValue()
            }
            return value
        }
    }
}

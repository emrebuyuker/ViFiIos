@preconcurrency import FirebaseDatabase
import Foundation
import os

/// Reads the app-update policy from the Realtime Database `config/appUpdate/ios` node with a live listener.
///
/// The node is tiny and kept synced, so after the first launch the policy is available offline (the last
/// value the device saw). A live `observe(.value)` listener re-emits whenever the policy changes — including
/// when the fresh server value replaces a stale cached one shortly after launch — so the update gate reacts
/// immediately instead of being stuck with a one-shot cached read. Reads never require a signed-in user —
/// the gate must work on the login screen too — but App Check still guards them.
///
/// The snapshot is parsed inside the Firebase callback, on the database's background queue, so the
/// non-sendable `DataSnapshot` never leaves it.
final class FirebaseRemoteConfigReader: AppConfigReading {
    private static let path = "config/appUpdate/ios"

    private let reference: DatabaseReference

    init(database: Database = ViFiDatabase.shared) {
        reference = database.reference(withPath: Self.path)
        // One tiny node: keeping it synced makes the policy available offline from the first launch.
        reference.keepSynced(true)
    }

    func configChanges() -> AsyncStream<AppUpdateConfig?> {
        // `DatabaseReference` is thread-safe but not annotated `Sendable`.
        nonisolated(unsafe) let reference = reference
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let handle = reference.observe(
                .value,
                with: { @Sendable snapshot in continuation.yield(Self.parse(snapshot.value)) },
                withCancel: { @Sendable error in
                    // A rejected listener means the policy is unreadable; `nil` lets the checker keep any
                    // active gate latched rather than silently opening the app.
                    Logger.app.error("Update config listener cancelled: \(String(describing: error), privacy: .public)")
                    continuation.yield(nil)
                }
            )
            continuation.onTermination = { @Sendable _ in
                reference.removeObserver(withHandle: handle)
            }
        }
    }

    /// Parses the node's value, keeping only well-formed fields; a non-string or empty field is dropped.
    nonisolated static func parse(_ value: Any?) -> AppUpdateConfig? {
        guard let object = value as? [String: Any] else { return nil }
        func string(_ key: String) -> String? {
            guard let text = object[key] as? String, !text.isEmpty else { return nil }
            return text
        }
        return AppUpdateConfig(
            minimumVersion: string("minimumVersion"),
            latestVersion: string("latestVersion"),
            storeURL: string("storeURL").flatMap(URL.init(string:)),
            message: string("message")
        )
    }
}

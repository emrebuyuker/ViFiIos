@preconcurrency import FirebaseDatabase
import Foundation
import os

/// Reads `config/captureProtection/ios` from the Realtime Database with a live listener, following
/// `FirebaseRemoteConfigReader`: the node is tiny and kept synced, reads need no sign-in (App Check still guards
/// them), and the snapshot is parsed inside the Firebase callback so the non-sendable `DataSnapshot` never leaves it.
final class FirebaseCaptureShieldConfigReader: CaptureShieldConfigReading {
    private static let path = "config/captureProtection/ios"

    private let reference: DatabaseReference

    init(database: Database = ViFiDatabase.shared) {
        reference = database.reference(withPath: Self.path)
        reference.keepSynced(true)
    }

    func configChanges() -> AsyncStream<CaptureShieldConfig?> {
        // `DatabaseReference` is thread-safe but not annotated `Sendable`.
        nonisolated(unsafe) let reference = reference
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let handle = reference.observe(
                .value,
                with: { @Sendable snapshot in continuation.yield(CaptureShieldConfig.parse(snapshot.value)) },
                withCancel: { @Sendable error in
                    // Unreadable: `nil` keeps the stored value rather than resetting it to the default.
                    Logger.app.error("Capture shield config listener cancelled: \(String(describing: error), privacy: .public)")
                    continuation.yield(nil)
                }
            )
            continuation.onTermination = { @Sendable _ in
                reference.removeObserver(withHandle: handle)
            }
        }
    }
}

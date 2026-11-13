@preconcurrency import FirebaseDatabase
import Foundation
import os

/// Reads `config/structuredExams/ios` from the Realtime Database with a live listener, exactly like
/// `FirebaseCaptureShieldConfigReader`: tiny synced node, parsed inside the callback so `DataSnapshot` never leaves it.
final class FirebaseStructuredExamsConfigReader: StructuredExamsConfigReading {
    private static let path = "config/structuredExams/ios"

    private let reference: DatabaseReference

    init(database: Database = ViFiDatabase.shared) {
        reference = database.reference(withPath: Self.path)
        reference.keepSynced(true)
    }

    func configChanges() -> AsyncStream<StructuredExamsConfig?> {
        // `DatabaseReference` is thread-safe but not annotated `Sendable`.
        nonisolated(unsafe) let reference = reference
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let handle = reference.observe(
                .value,
                with: { @Sendable snapshot in continuation.yield(StructuredExamsConfig.parse(snapshot.value)) },
                withCancel: { @Sendable error in
                    // Unreadable: `nil` keeps the stored value rather than resetting it to the default.
                    Logger.app.error("Structured exams config listener cancelled: \(String(describing: error), privacy: .public)")
                    continuation.yield(nil)
                }
            )
            continuation.onTermination = { @Sendable _ in
                reference.removeObserver(withHandle: handle)
            }
        }
    }
}

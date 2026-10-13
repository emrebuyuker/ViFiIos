@preconcurrency import FirebaseDatabase
import Foundation
import os

/// Reads the reward values from the Realtime Database `config/rewards/ios` node with a live listener.
///
/// Mirrors `FirebaseRemoteConfigReader`: a tiny, kept-synced node parsed inside the Firebase callback so the
/// non-sendable `DataSnapshot` never leaves it. Reads never require a signed-in user (the add-exam flow may
/// read it before anything else loads); App Check still guards them.
final class FirebaseRewardsConfigReader: RewardsConfigReading {
    private static let path = "config/rewards/ios"

    private let reference: DatabaseReference

    init(database: Database = ViFiDatabase.shared) {
        reference = database.reference(withPath: Self.path)
        reference.keepSynced(true)
    }

    func rewardsChanges() -> AsyncStream<RewardsConfig?> {
        // `DatabaseReference` is thread-safe but not annotated `Sendable`.
        nonisolated(unsafe) let reference = reference
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let handle = reference.observe(
                .value,
                with: { @Sendable snapshot in continuation.yield(Self.parse(snapshot.value)) },
                withCancel: { @Sendable error in
                    Logger.app.error("Rewards config listener cancelled: \(String(describing: error), privacy: .public)")
                    continuation.yield(nil)
                }
            )
            continuation.onTermination = { @Sendable _ in
                reference.removeObserver(withHandle: handle)
            }
        }
    }

    /// Parses the node's value. RTDB numbers arrive as `NSNumber`; a missing or non-positive count is dropped.
    /// The optional `tiers` child carries the per-tier amounts keyed by `SubmissionTier.rawValue`.
    nonisolated static func parse(_ value: Any?) -> RewardsConfig? {
        guard let object = value as? [String: Any] else { return nil }
        let coins = positiveInt(object["examUploadCoins"])
        let tiers = parseTiers(object["tiers"])
        return RewardsConfig(examUploadCoins: coins, tiers: tiers)
    }

    /// Reads the `tiers` child into a `SubmissionTier`-keyed map, dropping unknown keys and non-positive values.
    nonisolated private static func parseTiers(_ value: Any?) -> [SubmissionTier: Int] {
        guard let object = value as? [String: Any] else { return [:] }
        var tiers: [SubmissionTier: Int] = [:]
        for (key, raw) in object {
            guard let tier = SubmissionTier(rawValue: key), let coins = positiveInt(raw) else { continue }
            tiers[tier] = coins
        }
        return tiers
    }

    /// A strictly positive `Int` from an RTDB `NSNumber`, else `nil`.
    nonisolated private static func positiveInt(_ value: Any?) -> Int? {
        guard let number = (value as? NSNumber)?.intValue, number > 0 else { return nil }
        return number
    }
}

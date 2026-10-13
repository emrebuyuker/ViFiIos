import Foundation

/// Remote reward values for user contributions, stored at `config/rewards/ios` in the database.
///
/// Everything is optional: with nothing configured the add-exam flow shows a generic "you'll earn coins" note
/// instead of a specific amount. The crediting happens when an admin approves the submission; these values are
/// only what the UI promises the user up front and the amounts an approval awards, so they can be tuned from
/// the console without an app update.
///
/// `tiers` holds the per-novelty-tier amounts (`config/rewards/ios/tiers/{newUniversity…duplicate}`);
/// `examUploadCoins` is the legacy flat value kept as a fallback when a tier has no explicit amount.
nonisolated struct RewardsConfig: Equatable, Sendable {
    /// Legacy flat award for an approved submission; the fallback when a tier is not configured.
    var examUploadCoins: Int?
    /// Coins per contribution tier (always positive when present). Empty when none are configured.
    var tiers: [SubmissionTier: Int] = [:]

    /// The coins promised for a submission of `tier`: its configured amount, else the legacy flat value, else
    /// `nil` (nothing is promised and the UI shows a generic note).
    func coins(for tier: SubmissionTier) -> Int? {
        tiers[tier] ?? examUploadCoins
    }
}

/// Reads the reward configuration (the `config/rewards` subtree) from the backend.
protocol RewardsConfigReading: AnyObject {
    /// A live stream of the reward values: the current value, then again on every change. Emits `nil` when the
    /// values are missing, malformed, or the read is rejected. The stream ends when the consuming task is
    /// cancelled.
    func rewardsChanges() -> AsyncStream<RewardsConfig?>
}

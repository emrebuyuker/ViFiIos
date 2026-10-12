import Foundation
import os

/// Warms the archive's offline cache after sign-in, so browsing a branch the user has not visited still works
/// without a connection.
///
/// Firestore has no `keepSynced`: only the queries a user actually runs are cached, so an offline list for an
/// un-visited branch comes back empty. A one-shot fetch of every published document fixes that (see
/// `ArchiveRepository.prefetchArchive()`). The warm is:
/// - **best-effort** — a failure (typically offline) is ignored and retried on the next launch;
/// - **throttled** — a successful warm is not repeated until `throttle` has passed, so the bulk read is not
///   billed on every launch while the cached copy stays fresh enough for offline use.
///
/// Sources without a remote cache to warm (sample data, the Realtime Database) implement `prefetchArchive()`
/// as a no-op, so this is safe to run in every environment.
final class ArchivePrefetcher {
    /// A successful warm is not repeated for this long.
    static let throttle: TimeInterval = 12 * 60 * 60

    private static let lastPrefetchKey = "archivePrefetchedAt"

    private let repository: any ArchiveRepository
    private let defaults: UserDefaults
    private let now: () -> Date
    /// Guards against a second warm starting while one is already in flight.
    private var isPrefetching = false

    init(
        repository: any ArchiveRepository,
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = { Date() }
    ) {
        self.repository = repository
        self.defaults = defaults
        self.now = now
    }

    /// Warms the cache when it is stale and no warm is already running; returns once the warm finishes, or
    /// immediately when it is skipped. Call it from the archive's `.task` so it is cancelled on sign-out.
    func prefetchIfNeeded() async {
        guard !isPrefetching, isStale else { return }
        isPrefetching = true
        defer { isPrefetching = false }
        do {
            try await repository.prefetchArchive()
            defaults.set(now(), forKey: Self.lastPrefetchKey)
            Logger.archive.debug("Archive prefetch complete")
        } catch is CancellationError {
            // Cancelled (e.g. sign-out before it finished): nothing recorded, so the next launch retries.
        } catch {
            Logger.archive.notice("Archive prefetch skipped: \(String(describing: error), privacy: .public)")
        }
    }

    /// Whether the last successful warm is old enough — or never happened — to warm again.
    private var isStale: Bool {
        guard let last = defaults.object(forKey: Self.lastPrefetchKey) as? Date else { return true }
        return now().timeIntervalSince(last) >= Self.throttle
    }
}

import Foundation

/// Decides whether the installed app may keep running, from the remote update policy.
///
/// The decision is driven entirely by `config/appUpdate/ios`, not the App Store listing, so a required
/// update takes effect immediately and on our own schedule — without waiting for App Store propagation,
/// and unaffected by storefront or phased-release quirks of the public lookup API.
///
/// A required update is **latched**: once the gate is required, a later policy read that comes back
/// unreadable (`nil`) keeps the gate instead of silently reopening the app. The gate only lifts on a
/// successful read that proves the installed version now meets the requirement.
final class RemoteAppUpdateChecker: AppUpdateChecking {
    private let config: any AppConfigReading
    private let installedVersion: String
    private let fallbackStoreURL: URL?

    /// - Parameters:
    ///   - config: Source of the remote update policy.
    ///   - installedVersion: The running app's `CFBundleShortVersionString`.
    ///   - fallbackStoreURL: Used only when the policy omits `storeURL`.
    init(
        config: any AppConfigReading,
        installedVersion: String = Bundle.main.shortVersionString,
        fallbackStoreURL: URL? = AppStoreLink.productURL
    ) {
        self.config = config
        self.installedVersion = installedVersion
        self.fallbackStoreURL = fallbackStoreURL
    }

    func statusChanges() -> AsyncStream<AppUpdateStatus> {
        let configStream = config.configChanges()
        let installedVersion = installedVersion
        let fallbackStoreURL = fallbackStoreURL
        return AsyncStream { continuation in
            let task = Task {
                var latched: AppUpdate?
                for await config in configStream {
                    let status: AppUpdateStatus
                    if let config {
                        status = Self.status(for: config, installedVersion: installedVersion, fallbackStoreURL: fallbackStoreURL)
                    } else {
                        // Unreadable policy: keep an active gate, otherwise stay up to date.
                        status = latched.map(AppUpdateStatus.required) ?? .upToDate
                    }
                    if case let .required(update) = status {
                        latched = update
                    } else if config != nil {
                        // A successful read with no requirement clears the gate; an unreadable one does not.
                        latched = nil
                    }
                    continuation.yield(status)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The requirement implied by `config` alone, comparing the installed version against the policy.
    ///
    /// Returns `.upToDate` when there is nowhere to send the user (no `storeURL` and no fallback), since
    /// prompting without a destination would be a dead end.
    nonisolated static func status(
        for config: AppUpdateConfig,
        installedVersion: String,
        fallbackStoreURL: URL?
    ) -> AppUpdateStatus {
        guard let storeURL = config.storeURL ?? fallbackStoreURL else { return .upToDate }

        if let minimumVersion = config.minimumVersion,
           AppVersion.isVersion(minimumVersion, newerThan: installedVersion) {
            return .required(AppUpdate(version: minimumVersion, storeURL: storeURL, message: config.message))
        }
        if let latestVersion = config.latestVersion,
           AppVersion.isVersion(latestVersion, newerThan: installedVersion) {
            return .optional(AppUpdate(version: latestVersion, storeURL: storeURL, message: config.message))
        }
        return .upToDate
    }
}

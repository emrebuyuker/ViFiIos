import Foundation

/// The remote update policy for this platform, stored at `config/appUpdate/ios` in the database.
///
/// Every field is optional: a missing `minimumVersion` disables the hard gate, a missing `latestVersion`
/// disables the optional prompt, and a missing `storeURL` falls back to `AppStoreLink.productURL`.
nonisolated struct AppUpdateConfig: Equatable, Sendable {
    var minimumVersion: String?
    var latestVersion: String?
    var storeURL: URL?
    var message: String?
}

/// Reads remote configuration (the `config` subtree) from the backend.
protocol AppConfigReading: AnyObject {
    /// A live stream of the update policy: the current value, then again on every change. Emits `nil`
    /// when the policy is missing, malformed, or the read is rejected. The stream ends when the
    /// consuming task is cancelled.
    func configChanges() -> AsyncStream<AppUpdateConfig?>
}

/// Where to send a user who needs to update.
enum AppStoreLink {
    /// The app's App Store page, used only when the remote config omits `storeURL`.
    ///
    /// The remote config's `storeURL` is the primary source; this is the built-in safety net.
    static let productURL: URL? = URL(string: "https://apps.apple.com/tr/app/vifi/id6670324094")
}

extension Bundle {
    /// `CFBundleShortVersionString` ("3.0.1"), or "0" when it is somehow absent.
    var shortVersionString: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}

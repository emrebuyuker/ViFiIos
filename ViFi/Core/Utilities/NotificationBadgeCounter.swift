import Foundation

/// The app icon badge, shared between the app and its Notification Service Extension through the App Group's
/// defaults (NOTIFICATIONS.md §5).
///
/// The app records every badge it sets (zero while it is open, the unread count when it goes to the background);
/// the extension, which runs for every push while the app is away, shows one more than the recorded badge and
/// records that, so a string of pushes counts up from the app's last number. The next time the app is opened it
/// replaces the number with its own again, so a missed or extra increment never lingers.
///
/// Compiled into both the app and the extension target, so it uses Foundation only.
nonisolated struct NotificationBadgeCounter {
    /// The App Group both targets are entitled to (`ViFi.entitlements`, `ViFiNotificationService.entitlements`).
    static let appGroup = "group.com.BuyukerYazilim.ViFi2"
    /// Bump the suffix on an incompatible change: the old value is then ignored.
    static let key = "notifications.badge.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The counter in the App Group's defaults, or `nil` when they cannot be opened. (In a build without the App
    /// Group entitlement, e.g. an unsigned one, the defaults are the target's own and simply not shared.)
    static func shared() -> NotificationBadgeCounter? {
        UserDefaults(suiteName: appGroup).map(NotificationBadgeCounter.init(defaults:))
    }

    /// The last recorded badge; never negative.
    var current: Int {
        max(0, defaults.integer(forKey: Self.key))
    }

    /// Records the badge the app has just set on its icon.
    func record(_ badge: Int) {
        defaults.set(max(0, badge), forKey: Self.key)
    }

    /// A push arrived: one more than the recorded badge, which becomes the recorded badge.
    @discardableResult
    func increment() -> Int {
        let current = current
        let next = current < Int.max ? current + 1 : current
        record(next)
        return next
    }
}

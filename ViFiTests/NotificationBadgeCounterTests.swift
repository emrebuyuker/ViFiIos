import Foundation
import Testing
@testable import ViFi

/// The icon badge the app and its Notification Service Extension share (`NotificationBadgeCounter`), on a throwaway
/// defaults suite instead of the App Group.
@Suite("NotificationBadgeCounter")
struct NotificationBadgeCounterTests {
    private let defaults: UserDefaults

    init() throws {
        let suite = "NotificationBadgeCounterTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
    }

    @Test("Starts at zero")
    func startsAtZero() {
        #expect(NotificationBadgeCounter(defaults: defaults).current == 0)
    }

    @Test("Each push counts up from the badge the app last set")
    func pushesCountUpFromTheAppsBadge() {
        let app = NotificationBadgeCounter(defaults: defaults)
        app.record(3) // the app went to the background with 3 unread

        let extensionSide = NotificationBadgeCounter(defaults: defaults)
        #expect(extensionSide.increment() == 4)
        #expect(extensionSide.increment() == 5)
        #expect(app.current == 5)
    }

    @Test("Opening the app resets what the next push counts from")
    func appResets() {
        let counter = NotificationBadgeCounter(defaults: defaults)
        counter.increment()
        counter.increment()

        counter.record(0) // the app became active

        #expect(counter.increment() == 1)
    }

    @Test("A negative or corrupt value never shows")
    func neverNegative() {
        let counter = NotificationBadgeCounter(defaults: defaults)
        counter.record(-5)
        #expect(counter.current == 0)

        defaults.set(-7, forKey: NotificationBadgeCounter.key)
        #expect(counter.current == 0)
        #expect(counter.increment() == 1)

        defaults.set("not a number", forKey: NotificationBadgeCounter.key)
        #expect(counter.current == 0)
    }

    @Test("The largest value does not overflow")
    func noOverflow() {
        let counter = NotificationBadgeCounter(defaults: defaults)
        counter.record(Int.max)
        #expect(counter.increment() == Int.max)
    }

    @Test("Both targets share the App Group's defaults")
    func appGroup() {
        #expect(NotificationBadgeCounter.appGroup == "group.com.BuyukerYazilim.ViFi2")
    }
}

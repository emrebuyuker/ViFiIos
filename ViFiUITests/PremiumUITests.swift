import XCTest

/// The premium subscription surfaces on the bundled mock archive (`-ViFiMockData`). `-ViFiSubscribed` reports an
/// active subscription, which must unlock the whole archive and hide the coin economy; without it, the account
/// screen offers the paywall and a purchase (via the mock store) flips the app into the subscribed state.
///
/// `nonisolated` because `XCTestCase`'s initializers are; the tests themselves drive the UI on the main actor.
nonisolated final class PremiumUITests: XCTestCase {
    private enum Timeout {
        static let transition: TimeInterval = 5
        static let content: TimeInterval = 15
    }

    /// A mock course whose two newest exams ("2023 VİZE", "2022 FİNAL") are locked for a free user.
    private let engineeringMathematics = [
        "BOZOK ÜNİVERSİTESİ",
        "MÜHENDİSLİK MİMARLIK FAKÜLTESİ",
        "BİLGİSAYAR MÜHENDİSLİĞİ",
        "MÜHENDİSLİK MATEMATİĞİ",
    ]

    @MainActor
    func testSubscriberHasNoLockedExamsAndNoCoinBadge() {
        let app = launchApp(subscribed: true)
        XCTAssertFalse(app.element("coin.balance").exists, "The coin badge must be hidden for a subscriber")

        openRows(engineeringMathematics, in: app)
        // The newest exam is locked for a free user; a subscriber opens it straight away.
        tap("row.2023 VİZE", in: app)
        XCTAssertTrue(app.element("exam.images").waitForExistence(timeout: Timeout.content),
                      "A subscriber should open a normally-locked exam directly")
        XCTAssertFalse(app.element("exam.unlock.sheet").exists, "A subscriber must never see the unlock sheet")
    }

    @MainActor
    func testAccountShowsActivePremiumAndHidesCoins() {
        let app = launchApp(subscribed: true)
        tap("toolbar.account", in: app)
        XCTAssertTrue(app.element("account.sheet").waitForExistence(timeout: Timeout.transition))
        XCTAssertTrue(app.element("account.premium.active").waitForExistence(timeout: Timeout.transition),
                      "The account should show the active premium status")
        XCTAssertFalse(app.element("account.coinBalance").exists, "Coins must be hidden for a subscriber")
        XCTAssertFalse(app.element("account.premium.upgrade").exists, "A subscriber should not see the upgrade row")
    }

    @MainActor
    func testUpgradingFromAccountOpensPaywallAndSubscribes() {
        let app = launchApp(subscribed: false)
        tap("toolbar.account", in: app)
        XCTAssertTrue(app.element("account.premium.upgrade").waitForExistence(timeout: Timeout.transition),
                      "A free user should see the upgrade row")

        tap("account.premium.upgrade", in: app)
        XCTAssertTrue(app.element("paywall.sheet").waitForExistence(timeout: Timeout.transition),
                      "The paywall did not appear")
        // Wait for the plans to load (the mock store has a short latency) so the subscribe button is enabled.
        XCTAssertTrue(app.element("paywall.option.yearly").waitForExistence(timeout: Timeout.content),
                      "The subscription plans did not load")

        // The mock store completes the purchase, which flips the app into the subscribed state and closes the
        // paywall, revealing the active status on the account screen underneath.
        tap("paywall.subscribe", in: app)
        XCTAssertTrue(app.element("account.premium.active").waitForExistence(timeout: Timeout.content),
                      "Purchasing did not activate premium")
    }

    // MARK: - Helpers

    @MainActor
    private func launchApp(subscribed: Bool) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = subscribed ? ["-ViFiMockData", "-ViFiSubscribed"] : ["-ViFiMockData"]
        app.launch()
        XCTAssertTrue(app.element("home.list").waitForExistence(timeout: Timeout.content), "The home list did not appear")
        return app
    }

    @MainActor
    private func openRows(_ names: [String], in app: XCUIApplication) {
        for name in names {
            let row = app.element("row.\(name)")
            XCTAssertTrue(row.waitForExistence(timeout: Timeout.content), "Row \(name) did not appear")
            for _ in 0..<5 where !row.isHittable { app.swipeUp() }
            row.tap()
        }
    }

    @MainActor
    private func tap(_ identifier: String, in app: XCUIApplication) {
        let target = app.element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: Timeout.transition), "\(identifier) did not appear")
        for _ in 0..<5 where !target.isHittable { app.swipeUp() }
        target.tap()
    }
}

private extension XCUIApplication {
    /// The first element with `identifier`, whatever its type.
    func element(_ identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}

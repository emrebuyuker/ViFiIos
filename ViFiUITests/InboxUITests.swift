import XCTest

/// The notification inbox on the bundled mock archive (`-ViFiMockData`): the home screen's bell opens the list of
/// public announcements and the user's own notifications, whose actions open an exam or the premium screen; a
/// tapped push (`-ViFiOpenNotification <id>`) opens the inbox on its notification.
///
/// `nonisolated` because `XCTestCase`'s initializers are; the tests drive the UI on the main actor.
nonisolated final class InboxUITests: XCTestCase {
    private enum Timeout {
        static let transition: TimeInterval = 5
        static let content: TimeInterval = 15
    }

    @MainActor
    func testOpeningTheInboxShowsAnnouncements() {
        let app = launchApp()

        openInbox(in: app)

        XCTAssertTrue(app.element("inbox.row.a1").waitForExistence(timeout: Timeout.content),
                      "The sample announcement row did not appear")
    }

    @MainActor
    func testInboxMergesBothSourcesAndHidesExpiredEntries() {
        let app = launchApp()

        openInbox(in: app)

        for id in ["a1", "p-exam", "p-paywall", "a2"] {
            XCTAssertTrue(app.element("inbox.row.\(id)").waitForExistence(timeout: Timeout.content), "\(id) is missing")
        }
        XCTAssertFalse(app.element("inbox.row.a-expired").exists, "An expired notification must not be shown")
        XCTAssertFalse(app.element("inbox.row.a1.action").exists, "A notification without an action has no button")
    }

    @MainActor
    func testExamActionOpensTheExamBehindTheInbox() {
        let app = launchApp()
        openInbox(in: app)

        tap("inbox.row.p-exam.action", in: app)

        XCTAssertTrue(app.element("exam.pdf").waitForExistence(timeout: Timeout.content), "The exam did not open")
        XCTAssertTrue(app.element("inbox.list").waitForNonExistence(timeout: Timeout.transition), "The inbox should have closed")
    }

    @MainActor
    func testTappingTheCardRunsTheAction() {
        let app = launchApp()
        openInbox(in: app)

        tap("inbox.row.p-exam", in: app)

        XCTAssertTrue(app.element("exam.pdf").waitForExistence(timeout: Timeout.content), "The card tap did not open the exam")
    }

    @MainActor
    func testPremiumActionOpensThePaywall() {
        let app = launchApp()
        openInbox(in: app)

        tap("inbox.row.p-paywall.action", in: app)

        XCTAssertTrue(app.element("paywall.close").waitForExistence(timeout: Timeout.transition), "The paywall did not open")
    }

    @MainActor
    func testSubscribersAreNotOfferedThePremiumButton() {
        let app = launchApp(extra: ["-ViFiSubscribed"])

        openInbox(in: app)

        XCTAssertTrue(app.element("inbox.row.p-paywall").waitForExistence(timeout: Timeout.content))
        XCTAssertFalse(app.element("inbox.row.p-paywall.action").exists)
    }

    // MARK: - Tapped push

    @MainActor
    func testTappedPushOpensTheInboxOnItsNotification() {
        let app = launchApp(extra: ["-ViFiOpenNotification", "p-paywall"])

        XCTAssertTrue(app.element("inbox.list").waitForExistence(timeout: Timeout.content), "The inbox did not open by itself")
        let row = app.element("inbox.row.p-paywall")
        XCTAssertTrue(row.waitForExistence(timeout: Timeout.content))
        XCTAssertTrue(row.isSelected, "The notification of the push should be highlighted")
        XCTAssertFalse(app.element("inbox.row.a1").isSelected, "Only the tapped notification is highlighted")
    }

    @MainActor
    func testTappedPushOfAnUnknownNotificationJustOpensTheInbox() {
        let app = launchApp(extra: ["-ViFiOpenNotification", "does-not-exist"])

        XCTAssertTrue(app.element("inbox.list").waitForExistence(timeout: Timeout.content), "The inbox did not open by itself")
        XCTAssertTrue(app.element("inbox.row.a1").waitForExistence(timeout: Timeout.content))
        XCTAssertFalse(app.element("inbox.row.a1").isSelected)
        XCTAssertFalse(app.element("inbox.row.p-paywall").isSelected)
    }

    @MainActor
    func testClosingTheInboxOpenedByAPushReturnsToHome() {
        let app = launchApp(extra: ["-ViFiOpenNotification", "a1"])
        XCTAssertTrue(app.element("inbox.list").waitForExistence(timeout: Timeout.content))

        tap("inbox.done", in: app)

        XCTAssertTrue(app.element("home.list").waitForExistence(timeout: Timeout.transition), "Home did not come back")
        XCTAssertTrue(app.element("inbox.list").waitForNonExistence(timeout: Timeout.transition), "The inbox must not reopen")
    }

    // MARK: - Helpers

    @MainActor
    private func launchApp(extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ViFiMockData"] + extra
        app.launch()
        return app
    }

    @MainActor
    private func openInbox(in app: XCUIApplication) {
        XCTAssertTrue(app.element("home.list").waitForExistence(timeout: Timeout.content), "The home list did not appear")
        tap("toolbar.inbox", in: app)
        XCTAssertTrue(app.element("inbox.list").waitForExistence(timeout: Timeout.transition), "The inbox did not open")
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

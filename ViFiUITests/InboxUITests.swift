import XCTest

/// The notification inbox on the bundled mock archive (`-ViFiMockData`): the home screen's bell opens the
/// announcements list, which shows the sample announcements.
///
/// `nonisolated` because `XCTestCase`'s initializers are; the tests drive the UI on the main actor.
nonisolated final class InboxUITests: XCTestCase {
    private enum Timeout {
        static let transition: TimeInterval = 5
        static let content: TimeInterval = 15
    }

    @MainActor
    func testOpeningTheInboxShowsAnnouncements() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ViFiMockData"]
        app.launch()
        XCTAssertTrue(app.element("home.list").waitForExistence(timeout: Timeout.content), "The home list did not appear")

        tap("toolbar.inbox", in: app)

        XCTAssertTrue(app.element("inbox.list").waitForExistence(timeout: Timeout.transition), "The inbox did not open")
        XCTAssertTrue(app.element("inbox.row.a1").waitForExistence(timeout: Timeout.content),
                      "The sample announcement row did not appear")
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

import XCTest

/// The first-launch onboarding tour (`-ViFiShowOnboarding`): it appears over the home screen, can be paged
/// through to the end and finished, or skipped at any point — and it does not appear on an ordinary mock
/// launch, so the rest of the UI suite reaches the archive unobstructed.
///
/// `nonisolated` because `XCTestCase`'s initializers are; the tests themselves drive the UI on the main actor.
nonisolated final class OnboardingUITests: XCTestCase {
    private enum Timeout {
        static let transition: TimeInterval = 5
        static let content: TimeInterval = 15
    }

    @MainActor
    func testTourAppearsAndCanBePagedToTheEnd() {
        let app = launchApp(showOnboarding: true)
        XCTAssertTrue(app.element("onboarding.pager").waitForExistence(timeout: Timeout.content),
                      "The onboarding tour did not appear")

        // Four pages: three "İleri" taps reach the last page, then "Başla" finishes.
        tap("onboarding.next", in: app)
        tap("onboarding.next", in: app)
        tap("onboarding.next", in: app)
        tap("onboarding.start", in: app)

        XCTAssertTrue(app.element("home.list").waitForExistence(timeout: Timeout.content),
                      "Finishing the tour did not reveal the home list")
        XCTAssertFalse(app.element("onboarding.pager").exists, "The tour should be gone after finishing")
    }

    @MainActor
    func testTourCanBeSkipped() {
        let app = launchApp(showOnboarding: true)
        XCTAssertTrue(app.element("onboarding.pager").waitForExistence(timeout: Timeout.content),
                      "The onboarding tour did not appear")

        tap("onboarding.skip", in: app)

        XCTAssertTrue(app.element("home.list").waitForExistence(timeout: Timeout.content),
                      "Skipping the tour did not reveal the home list")
        XCTAssertFalse(app.element("onboarding.pager").exists, "The tour should be gone after skipping")
    }

    @MainActor
    func testTourIsHiddenOnAnOrdinaryLaunch() {
        let app = launchApp(showOnboarding: false)

        XCTAssertTrue(app.element("home.list").waitForExistence(timeout: Timeout.content),
                      "The home list did not appear")
        XCTAssertFalse(app.element("onboarding.pager").exists,
                       "The tour must not appear without -ViFiShowOnboarding")
    }

    // MARK: - Helpers

    @MainActor
    private func launchApp(showOnboarding: Bool) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = showOnboarding ? ["-ViFiMockData", "-ViFiShowOnboarding"] : ["-ViFiMockData"]
        app.launch()
        return app
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

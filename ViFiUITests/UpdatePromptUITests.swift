import XCTest

/// The optional "Yeni sürüm mevcut" alert on the bundled mock archive. `-ViFiOptionalUpdate` reports a newer,
/// optional version; dismissing the alert must keep it away for the rest of the launch.
///
/// `nonisolated` because `XCTestCase`'s initializers are; the tests themselves drive the UI on the main actor.
nonisolated final class UpdatePromptUITests: XCTestCase {
    private enum Timeout {
        static let transition: TimeInterval = 5
        static let content: TimeInterval = 15
        /// How long the alert must stay away after dismissal: it used to return within a fraction of a second.
        static let staysDismissed: TimeInterval = 3
    }

    private let alertTitle = "Yeni sürüm mevcut"

    @MainActor
    func testOptionalUpdateDismissedWithLaterDoesNotComeBack() {
        continueAfterFailure = false
        let app = XCUIApplication()
        // The argument domain overrides a version skipped in an earlier (manual) run, without touching it.
        app.launchArguments = ["-ViFiMockData", "-ViFiOptionalUpdate", "-skippedUpdateVersion", ""]
        app.launch()

        let alert = app.alerts[alertTitle]
        XCTAssertTrue(alert.waitForExistence(timeout: Timeout.content), "The optional update alert did not appear")
        alert.buttons["Daha Sonra"].tap()

        XCTAssertTrue(waitForDisappearance(of: alert, timeout: Timeout.transition), "The alert did not close")
        // SwiftUI writes the dismissal more than once; the alert must not be re-presented by a later write.
        XCTAssertFalse(
            alert.waitForExistence(timeout: Timeout.staysDismissed),
            "The optional update alert came back after \"Daha Sonra\""
        )
        let about = app.descendants(matching: .any).matching(identifier: "toolbar.about").firstMatch
        XCTAssertTrue(about.isHittable, "The home screen should be usable after dismissal")
    }

    @MainActor
    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}

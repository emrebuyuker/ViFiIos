import XCTest

/// The admin subject-mapping screen on the bundled mock data (`-ViFiMockData -ViFiAdmin`): the moderation entry,
/// the "Olası eşleşme" hint and merging two subjects.
nonisolated final class SubjectMappingUITests: XCTestCase {
    private enum Timeout {
        static let transition: TimeInterval = 5
        static let content: TimeInterval = 15
    }

    @MainActor
    func testAdminMergesTwoSubjects() {
        let app = launchApp()
        openSubjects(in: app)

        XCTAssertTrue(element("subjects.row.algoritma", in: app).exists, "The duplicate-looking subject is missing")
        XCTAssertTrue(element("subjects.possibleMatch", in: app).waitForExistence(timeout: Timeout.transition),
                      "The possible-match hint did not appear")

        tap("subjects.row.algoritma", in: app)
        XCTAssertTrue(element("subjects.detail", in: app).waitForExistence(timeout: Timeout.content))
        tap("subjects.menu", in: app)
        tap("subjects.merge", in: app)
        tap("subjects.picker.row.algoritmalar", in: app)

        // The confirmation explains what moves; confirming returns to the list without the merged subject.
        let confirm = app.alerts.buttons["Birleştir"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: Timeout.transition), "The merge confirmation did not appear")
        confirm.tap()

        XCTAssertTrue(element("subjects.list", in: app).waitForExistence(timeout: Timeout.content), "The list did not return")
        XCTAssertTrue(element("subjects.row.algoritmalar", in: app).waitForExistence(timeout: Timeout.transition))
        XCTAssertFalse(element("subjects.row.algoritma", in: app).exists, "The merged subject stayed in the list")
    }

    @MainActor
    func testAdminMovesACourseToAnotherSubject() {
        let app = launchApp()
        openSubjects(in: app)

        tap("subjects.row.fizik-2", in: app)
        tap("subjects.course.change", in: app)
        tap("subjects.picker.row.fizik-1", in: app)

        // The only course left Fizik 2, so the subject is empty but still listed; Fizik 1 now holds three courses.
        XCTAssertTrue(element("subjects.detail", in: app).waitForExistence(timeout: Timeout.content))
        app.buttons["BackButton"].firstMatch.tap()
        // The rows are combined accessibility elements, so the counts are matched on the label.
        let counts = NSPredicate(format: "label CONTAINS %@", "3 ders · 57 soru")
        XCTAssertTrue(app.descendants(matching: .any).matching(counts).firstMatch.waitForExistence(timeout: Timeout.content),
                      "Fizik 1 did not receive the course")
    }

    // MARK: - Helpers

    @MainActor
    private func launchApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ViFiMockData", "-ViFiAdmin"]
        app.launch()
        XCTAssertTrue(element("home.list", in: app).waitForExistence(timeout: Timeout.content), "The home list did not appear")
        return app
    }

    @MainActor
    private func openSubjects(in app: XCUIApplication) {
        tap("toolbar.account", in: app)
        tap("account.moderation", in: app)
        tap("moderation.subjects", in: app)
        XCTAssertTrue(element("subjects.list", in: app).waitForExistence(timeout: Timeout.content), "The subject list did not appear")
    }

    @MainActor
    private func tap(_ identifier: String, in app: XCUIApplication) {
        let target = element(identifier, in: app)
        XCTAssertTrue(target.waitForExistence(timeout: Timeout.transition), "\(identifier) did not appear")
        for _ in 0..<5 where !target.isHittable { app.swipeUp() }
        target.tap()
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}

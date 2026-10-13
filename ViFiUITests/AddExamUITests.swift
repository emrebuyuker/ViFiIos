import XCTest

/// The "Sınav Ekle" flow on the bundled mock archive (`-ViFiMockData`): the home call-to-action, the form with
/// profile-prefilled university/faculty/department, the fixed exam-name list, and the course picker. File
/// attachment uses the system pickers and crediting is server-side, so submit itself is covered by unit tests.
nonisolated final class AddExamUITests: XCTestCase {
    private enum Timeout {
        static let transition: TimeInterval = 5
        static let content: TimeInterval = 15
    }

    @MainActor
    func testAddExamFormPrefillsProfileAndPicksFields() {
        let app = launchApp()

        tap("home.addExam", in: app)

        // The form appears with university / faculty / department pre-filled from the signed-in profile.
        let university = element("addExam.university", in: app)
        XCTAssertTrue(university.waitForExistence(timeout: Timeout.transition), "The add-exam form did not appear")
        XCTAssertEqual(university.value as? String, "Boğaziçi Üniversitesi")
        XCTAssertEqual(element("addExam.department", in: app).value as? String, "Bilgisayar Mühendisliği")

        // The exam name is chosen from the fixed list (no free text).
        tap("addExam.examName", in: app)
        let examOption = element("addExam.examName.option", in: app)
        XCTAssertTrue(examOption.waitForExistence(timeout: Timeout.content), "The exam-name list did not appear")
        examOption.tap()
        XCTAssertEqual(element("addExam.examName", in: app).value as? String, "VİZE")

        // The course picker opens and offers the "add a different course" fallback.
        tap("addExam.lesson", in: app)
        XCTAssertTrue(element("lessonPicker.addCustom", in: app).waitForExistence(timeout: Timeout.content),
                      "The course picker did not appear")
    }

    // MARK: - Helpers

    @MainActor
    private func launchApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ViFiMockData"]
        app.launch()
        XCTAssertTrue(element("home.list", in: app).waitForExistence(timeout: Timeout.content), "The home list did not appear")
        return app
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

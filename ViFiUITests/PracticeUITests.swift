import XCTest

/// The 4.2.0 practice mode ("Sınava gir") on the mock archive (`-ViFiMockData`): the course screen's entry, the type and
/// scope steps, a session (reveal, next) and the free daily limit's paywall prompt.
nonisolated final class PracticeUITests: XCTestCase {
    private enum Timeout {
        static let content: TimeInterval = 15
    }

    private static let course = ["KOCAELİ ÜNİVERSİTESİ", "MÜHENDİSLİK FAKÜLTESİ", "MATEMATİK BÖLÜMÜ", "TOPOLOJİ 1"]
    private static let courseWithoutPractice = ["KOCAELİ ÜNİVERSİTESİ", "MÜHENDİSLİK FAKÜLTESİ", "MATEMATİK BÖLÜMÜ", "TOPOLOJİ 2"]

    @MainActor
    func testPracticeFlowFromCourseToQuestions() {
        let app = launch()
        open(Self.course, in: app)

        let start = element(app, "practice.start")
        XCTAssertTrue(start.waitForExistence(timeout: Timeout.content), "The course must offer \"Sınava gir\"")
        start.tap()

        // Type step: only types with questions (final and vize in the mock index).
        let finalType = element(app, "practice.type.final")
        XCTAssertTrue(finalType.waitForExistence(timeout: Timeout.content))
        XCTAssertTrue(element(app, "practice.type.vize").exists)
        XCTAssertFalse(element(app, "practice.type.butunleme").exists)
        finalType.tap()

        // Scope step: all three scopes for final, each with a count.
        let course = element(app, "practice.scope.course")
        XCTAssertTrue(course.waitForExistence(timeout: Timeout.content))
        XCTAssertTrue(element(app, "practice.scope.university").exists)
        XCTAssertTrue(element(app, "practice.scope.tr").exists)
        XCTAssertTrue(course.label.contains("3 soru"), "Scope row label was \(course.label)")
        course.tap()

        // Session: a question card, the free counter, reveal, next.
        XCTAssertTrue(element(app, "practice.session").waitForExistence(timeout: Timeout.content))
        XCTAssertTrue(element(app, "practice.remaining").waitForExistence(timeout: Timeout.content))
        let reveal = app.buttons["Cevabı Göster"].firstMatch
        XCTAssertTrue(reveal.waitForExistence(timeout: Timeout.content))
        reveal.tap()
        XCTAssertTrue(app.buttons["Cevabı Gizle"].firstMatch.waitForExistence(timeout: Timeout.content))

        let next = element(app, "practice.next")
        XCTAssertTrue(next.exists)
        next.tap()
        XCTAssertTrue(app.buttons["Cevabı Göster"].firstMatch.waitForExistence(timeout: Timeout.content),
                      "The next question starts with its answer hidden")

        element(app, "practice.finish").tap()
        XCTAssertTrue(element(app, "practice.start").waitForExistence(timeout: Timeout.content),
                      "Finishing returns to the course")
    }

    @MainActor
    func testCourseWithoutPracticeQuestionsHasNoEntry() {
        let app = launch()
        open(Self.courseWithoutPractice, in: app)

        XCTAssertTrue(element(app, "browse.list").waitForExistence(timeout: Timeout.content))
        XCTAssertFalse(element(app, "practice.start").waitForExistence(timeout: 2))
    }

    @MainActor
    func testFreeLimitReachedOffersThePaywall() {
        let app = launch(extra: ["-ViFiPracticeLimitReached"])
        open(Self.course, in: app)
        element(app, "practice.start").tap()
        element(app, "practice.type.final").tap()
        element(app, "practice.scope.tr").tap()

        XCTAssertTrue(element(app, "practice.limit").waitForExistence(timeout: Timeout.content))
        let paywall = element(app, "practice.paywall")
        XCTAssertTrue(paywall.exists)
        paywall.tap()
        XCTAssertTrue(element(app, "paywall.sheet").waitForExistence(timeout: Timeout.content))
    }

    @MainActor
    func testPremiumSeesNoCounter() {
        let app = launch(extra: ["-ViFiSubscribed"])
        open(Self.course, in: app)
        element(app, "practice.start").tap()
        element(app, "practice.type.final").tap()
        element(app, "practice.scope.tr").tap()

        XCTAssertTrue(element(app, "practice.session").waitForExistence(timeout: Timeout.content))
        XCTAssertFalse(element(app, "practice.remaining").exists)
    }

    // MARK: - Helpers

    @MainActor
    private func launch(extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ViFiMockData"] + extra
        app.launch()
        XCTAssertTrue(element(app, "home.list").waitForExistence(timeout: Timeout.content), "The home list did not appear")
        return app
    }

    @MainActor
    private func open(_ path: [String], in app: XCUIApplication) {
        for name in path {
            let row = element(app, "row.\(name)")
            XCTAssertTrue(row.waitForExistence(timeout: Timeout.content), "Row \(name) did not appear")
            for _ in 0..<5 where !row.isHittable { app.swipeUp() }
            row.tap()
        }
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}

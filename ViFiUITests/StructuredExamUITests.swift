import XCTest

/// The 4.2.0 structured exam screen on the mock archive (`-ViFiMockData`): a structured exam opens the question
/// list, "Cevabı Göster" reveals the answer, and the question surface passes the capture-shield self-test.
nonisolated final class StructuredExamUITests: XCTestCase {
    private enum Timeout {
        static let content: TimeInterval = 15
        static let selfTest: TimeInterval = 10
    }

    private static let lesson = ["KOCAELİ ÜNİVERSİTESİ", "MÜHENDİSLİK FAKÜLTESİ", "MATEMATİK BÖLÜMÜ", "TOPOLOJİ 1"]
    private static let structuredExam = "2003 FİNAL"
    private static let plainExam = "2002 VİZE"

    @MainActor
    func testStructuredExamOpensQuestionsAndRevealsAnswer() {
        let app = launch()
        open(Self.lesson + [Self.structuredExam], in: app)

        XCTAssertTrue(element(app, "questions.list").waitForExistence(timeout: Timeout.content))
        XCTAssertTrue(element(app, "questions.card.1").waitForExistence(timeout: Timeout.content))
        XCTAssertFalse(element(app, "questions.answer.1").exists, "The answer must stay hidden until revealed")

        let reveal = element(app, "questions.reveal.1")
        XCTAssertTrue(reveal.waitForExistence(timeout: Timeout.content))
        reveal.tap()

        XCTAssertTrue(element(app, "questions.answer.1").waitForExistence(timeout: Timeout.content))
    }

    @MainActor
    func testAdminSeesQuestionActionsAndOthersDoNot() {
        let admin = launch(admin: true)
        open(Self.lesson + [Self.structuredExam], in: admin)
        XCTAssertTrue(element(admin, "questions.card.1").waitForExistence(timeout: Timeout.content))
        XCTAssertTrue(element(admin, "questionAdmin.menu").waitForExistence(timeout: Timeout.content),
                      "The admin question menu must appear for an admin")
        admin.terminate()

        let user = launch()
        open(Self.lesson + [Self.structuredExam], in: user)
        XCTAssertTrue(element(user, "questions.card.1").waitForExistence(timeout: Timeout.content))
        XCTAssertFalse(element(user, "questionAdmin.menu").exists, "Non-admins must not see the admin menu")
    }

    @MainActor
    func testAdminSeesConvertActionOnAPlainExam() {
        let app = launch(admin: true)
        open(Self.lesson + [Self.plainExam], in: app)
        XCTAssertTrue(element(app, "exam.images").waitForExistence(timeout: Timeout.content))
        XCTAssertTrue(element(app, "examAdmin.convert").waitForExistence(timeout: Timeout.content),
                      "\"Yeni yapıya geçir\" must appear for an admin")
    }

    @MainActor
    func testStructuredExamRowShowsItsQuestionCount() {
        let app = launch()
        open(Self.lesson, in: app)

        let structuredRow = element(app, "row.\(Self.structuredExam)")
        XCTAssertTrue(structuredRow.waitForExistence(timeout: Timeout.content))
        XCTAssertTrue(structuredRow.label.contains("3 soru"), "Row label was \(structuredRow.label)")
        XCTAssertTrue(structuredRow.label.contains("Sorular"), "Row label was \(structuredRow.label)")

        let plainRow = element(app, "row.\(Self.plainExam)")
        XCTAssertTrue(plainRow.waitForExistence(timeout: Timeout.content))
        XCTAssertTrue(plainRow.label.contains("sayfa"), "Row label was \(plainRow.label)")
        XCTAssertFalse(plainRow.label.contains("soru"), "Row label was \(plainRow.label)")
    }

    @MainActor
    func testPlainExamKeepsTheFileViewer() {
        let app = launch()
        open(Self.lesson + [Self.plainExam], in: app)

        XCTAssertTrue(element(app, "exam.images").waitForExistence(timeout: Timeout.content))
        XCTAssertFalse(element(app, "questions.list").exists)
    }

    @MainActor
    func testQuestionSurfaceIsVerifiedByTheShieldSelfTest() {
        let app = launch(selfTest: true)
        open(Self.lesson + [Self.structuredExam], in: app)
        XCTAssertTrue(element(app, "questions.card.1").waitForExistence(timeout: Timeout.content))

        let markers = app.descendants(matching: .any).matching(identifier: "exam.shield.selfTest")
        XCTAssertTrue(markers.firstMatch.waitForExistence(timeout: Timeout.content), "No shielded surface on screen")
        let deadline = Date.now.addingTimeInterval(Timeout.selfTest)
        var values: [String] = []
        repeat {
            values = markers.allElementsBoundByIndex.compactMap { $0.value as? String }
            if !values.isEmpty, values.allSatisfy({ $0 != "pending" }) { break }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date.now < deadline
        XCTAssertFalse(values.isEmpty, "No self-test outcome was published")
        XCTAssertTrue(values.allSatisfy { $0 == "verified" }, "Self-test outcomes \(values), expected all verified")
    }

    // MARK: - Helpers

    @MainActor
    private func launch(selfTest: Bool = false, admin: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ViFiMockData"] + (selfTest ? ["-ViFiCaptureShieldSelfTest"] : []) + (admin ? ["-ViFiAdmin"] : [])
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

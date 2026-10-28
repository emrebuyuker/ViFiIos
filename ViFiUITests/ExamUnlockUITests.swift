import XCTest

/// The exam lock/unlock flow on the bundled mock archive (`-ViFiMockData`): a course's two newest exams are
/// locked, tapping one opens the unlock sheet, and the outcome depends on the coin balance — unlocking with
/// coins opens the exam, while an empty balance (`-ViFiNoCoins`) routes the user to adding exams to earn them.
///
/// `nonisolated` because `XCTestCase`'s initializers are; the tests themselves drive the UI on the main actor.
nonisolated final class ExamUnlockUITests: XCTestCase {
    private enum Timeout {
        static let transition: TimeInterval = 5
        static let content: TimeInterval = 15
    }

    /// University › faculty › department › lesson of the mock course whose two newest exams ("2023 VİZE",
    /// "2022 FİNAL") are locked and whose two oldest ("2019 FİNAL", "2018 VİZE") are free.
    private let engineeringMathematics = [
        "BOZOK ÜNİVERSİTESİ",
        "MÜHENDİSLİK MİMARLIK FAKÜLTESİ",
        "BİLGİSAYAR MÜHENDİSLİĞİ",
        "MÜHENDİSLİK MATEMATİĞİ",
    ]

    @MainActor
    func testUnlockingALockedExamWithCoinsOpensIt() {
        let app = launchApp(noCoins: false)
        openRows(engineeringMathematics, in: app)

        // The newest exam is locked; tapping it opens the unlock sheet rather than the viewer.
        tap("row.2023 VİZE", in: app)
        XCTAssertTrue(app.element("exam.unlock.sheet").waitForExistence(timeout: Timeout.transition),
                      "The unlock sheet did not appear for a locked exam")

        // With enough coins the confirm button spends them and opens the exam.
        tap("exam.unlock.confirm", in: app)

        XCTAssertTrue(app.element("exam.images").waitForExistence(timeout: Timeout.content),
                      "Unlocking did not open the exam")
    }

    @MainActor
    func testLockedExamWithoutCoinsOffersToEarnThem() {
        let app = launchApp(noCoins: true)
        openRows(engineeringMathematics, in: app)

        tap("row.2023 VİZE", in: app)
        XCTAssertTrue(app.element("exam.unlock.sheet").waitForExistence(timeout: Timeout.transition),
                      "The unlock sheet did not appear for a locked exam")
        XCTAssertFalse(app.element("exam.unlock.confirm").exists, "An empty balance must not offer to unlock")

        // The earn action closes the sheet and opens the add-exam form.
        tap("exam.unlock.earn", in: app)

        XCTAssertTrue(app.element("addExam.university").waitForExistence(timeout: Timeout.content),
                      "Earning coins did not open the add-exam form")
    }

    @MainActor
    func testBuyingALockedExamWithMoneyOpensIt() {
        let app = launchApp(noCoins: true)
        openRows(engineeringMathematics, in: app)

        // Even with no coins, the money option can unlock a single exam directly (mock store succeeds).
        tap("row.2023 VİZE", in: app)
        XCTAssertTrue(app.element("exam.unlock.sheet").waitForExistence(timeout: Timeout.transition),
                      "The unlock sheet did not appear for a locked exam")
        tap("exam.unlock.buy", in: app)

        XCTAssertTrue(app.element("exam.images").waitForExistence(timeout: Timeout.content),
                      "Buying the exam with money did not open it")
    }

    @MainActor
    func testFreeExamOpensWithoutTheUnlockSheet() {
        let app = launchApp(noCoins: false)
        openRows(engineeringMathematics + ["2018 VİZE"], in: app)

        XCTAssertTrue(app.element("exam.pdf").waitForExistence(timeout: Timeout.content),
                      "A free (oldest) exam should open directly")
        XCTAssertFalse(app.element("exam.unlock.sheet").exists, "A free exam must not show the unlock sheet")
    }

    // MARK: - Helpers

    @MainActor
    private func launchApp(noCoins: Bool) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = noCoins ? ["-ViFiMockData", "-ViFiNoCoins"] : ["-ViFiMockData"]
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

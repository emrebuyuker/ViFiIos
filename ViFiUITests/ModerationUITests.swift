import XCTest

/// The admin moderation flow on the bundled mock data (`-ViFiMockData -ViFiAdmin`): the account entry shown only
/// to admins, the pending queue, and approving a submission so it leaves the queue.
nonisolated final class ModerationUITests: XCTestCase {
    private enum Timeout {
        static let transition: TimeInterval = 5
        static let content: TimeInterval = 15
    }

    @MainActor
    func testAdminApprovesASubmission() {
        let app = launchApp(admin: true)

        tap("toolbar.account", in: app)
        tap("account.moderation", in: app)

        XCTAssertTrue(element("moderation.list", in: app).waitForExistence(timeout: Timeout.content),
                      "The moderation queue did not appear")
        XCTAssertTrue(element("moderation.row.sub-1", in: app).waitForExistence(timeout: Timeout.transition),
                      "The pending submission did not appear")

        tap("moderation.row.sub-1", in: app)
        tap("moderation.detail.approve", in: app)

        // The approval confirmation appears; dismissing it returns to the queue without the approved item.
        let done = app.buttons["Tamam"]
        XCTAssertTrue(done.waitForExistence(timeout: Timeout.content), "The approval confirmation did not appear")
        done.tap()

        XCTAssertTrue(element("moderation.row.sub-2", in: app).waitForExistence(timeout: Timeout.content),
                      "The queue did not return")
        XCTAssertFalse(element("moderation.row.sub-1", in: app).exists, "The approved submission stayed in the queue")
    }

    @MainActor
    func testModerationIsHiddenFromNonAdmins() {
        let app = launchApp(admin: false)

        tap("toolbar.account", in: app)

        XCTAssertTrue(element("account.sheet", in: app).waitForExistence(timeout: Timeout.content),
                      "The account sheet did not appear")
        // Give the admin-claim check time to resolve before asserting the row stays hidden.
        XCTAssertTrue(element("account.coinBalance", in: app).waitForExistence(timeout: Timeout.content))
        XCTAssertFalse(element("account.moderation", in: app).exists, "Moderation was shown to a non-admin")
    }

    @MainActor
    func testAdminDeletesAnExamFromArchive() {
        let app = launchApp(admin: true)

        // Drill into a course's exams in the bundled mock archive.
        tap("row.BOZOK ÜNİVERSİTESİ", in: app)
        tap("row.MÜHENDİSLİK MİMARLIK FAKÜLTESİ", in: app)
        tap("row.BİLGİSAYAR MÜHENDİSLİĞİ", in: app)
        tap("row.MÜHENDİSLİK MATEMATİĞİ", in: app)

        let exam = element("row.2019 FİNAL", in: app)
        XCTAssertTrue(exam.waitForExistence(timeout: Timeout.content), "The exam did not appear")

        exam.swipeLeft()
        let delete = element("browse.delete.2019 FİNAL", in: app)
        XCTAssertTrue(delete.waitForExistence(timeout: Timeout.transition), "The delete action did not appear")
        delete.tap()

        let confirm = app.alerts.buttons["Sil"]
        XCTAssertTrue(confirm.waitForExistence(timeout: Timeout.transition), "The delete confirmation did not appear")
        confirm.tap()

        XCTAssertTrue(exam.waitForNonExistence(timeout: Timeout.content), "The exam was not removed from the list")
    }

    // MARK: - Helpers

    @MainActor
    private func launchApp(admin: Bool) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = admin ? ["-ViFiMockData", "-ViFiAdmin"] : ["-ViFiMockData"]
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

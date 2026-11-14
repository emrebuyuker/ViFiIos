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
        tap("moderation.approve.claude", in: app)

        // The approval confirmation appears; dismissing it returns to the queue without the approved item.
        let done = app.buttons["Tamam"]
        XCTAssertTrue(done.waitForExistence(timeout: Timeout.content), "The approval confirmation did not appear")
        done.tap()

        XCTAssertTrue(element("moderation.row.sub-2", in: app).waitForExistence(timeout: Timeout.content),
                      "The queue did not return")
        XCTAssertFalse(element("moderation.row.sub-1", in: app).exists, "The approved submission stayed in the queue")
    }

    @MainActor
    func testQueueAndDetailShowTheSubmitter() {
        let app = launchApp(admin: true)

        tap("toolbar.account", in: app)
        tap("account.moderation", in: app)

        // The rows are combined accessibility elements, so the name is matched on the label.
        let name = NSPredicate(format: "label CONTAINS %@", "Ayşe Demir")
        let inList = app.descendants(matching: .any).matching(name).firstMatch
        XCTAssertTrue(inList.waitForExistence(timeout: Timeout.content), "The submitter did not appear in the queue")

        tap("moderation.row.sub-1", in: app)
        let inDetail = element("moderation.detail.submitter", in: app)
        XCTAssertTrue(inDetail.waitForExistence(timeout: Timeout.content), "The submitter did not appear in the detail")
        XCTAssertTrue(inDetail.label.contains("Ayşe Demir"), "The submitter's name is missing in the detail")
    }

    @MainActor
    func testMissingSubmitterProfileDoesNotBlockReview() {
        let app = launchApp(admin: true)

        tap("toolbar.account", in: app)
        tap("account.moderation", in: app)
        tap("moderation.row.sub-2", in: app)

        let note = element("moderation.detail.submitter", in: app)
        XCTAssertTrue(note.waitForExistence(timeout: Timeout.content), "The missing-profile note did not appear")
        XCTAssertTrue(reveal("moderation.approve.claude", in: app), "Approving is blocked without a profile")
    }

    @MainActor
    func testApprovalOffersBothProviders() {
        let app = launchApp(admin: true)

        tap("toolbar.account", in: app)
        tap("account.moderation", in: app)
        tap("moderation.row.sub-2", in: app)

        XCTAssertTrue(reveal("moderation.approve.claude", in: app),
                      "The Claude approval button did not appear")
        XCTAssertTrue(reveal("moderation.approve.gemini", in: app), "The Gemini approval button did not appear")

        tap("moderation.approve.gemini", in: app)

        let done = app.buttons["Tamam"]
        XCTAssertTrue(done.waitForExistence(timeout: Timeout.content), "The approval confirmation did not appear")
        done.tap()
        XCTAssertFalse(element("moderation.row.sub-2", in: app).waitForExistence(timeout: Timeout.transition),
                       "The approved submission stayed in the queue")
    }

    @MainActor
    func testDuplicateSubmissionShowsWarningAndBothButtons() {
        let app = launchApp(admin: true)

        tap("toolbar.account", in: app)
        tap("account.moderation", in: app)
        tap("moderation.row.sub-dup", in: app)

        XCTAssertTrue(element("moderation.duplicateWarning", in: app).waitForExistence(timeout: Timeout.content),
                      "The duplicate warning did not appear")
        XCTAssertTrue(reveal("moderation.approve.claude", in: app), "The Claude approval button did not appear")
        XCTAssertTrue(reveal("moderation.approve.gemini", in: app), "The Gemini approval button did not appear")
    }

    @MainActor
    func testNewSubmissionShowsNoDuplicateWarning() {
        let app = launchApp(admin: true)

        tap("toolbar.account", in: app)
        tap("account.moderation", in: app)
        tap("moderation.row.sub-2", in: app)

        XCTAssertTrue(reveal("moderation.approve.claude", in: app))
        XCTAssertFalse(element("moderation.duplicateWarning", in: app).exists, "A new submission showed the warning")
    }

    @MainActor
    func testAdminReviewsAndPublishesAReadyExam() {
        let app = launchApp(admin: true)

        tap("toolbar.account", in: app)
        tap("account.moderation", in: app)
        tap("moderation.ready", in: app)

        XCTAssertTrue(element("conversion.row.sub-sub-1", in: app).waitForExistence(timeout: Timeout.content),
                      "The ready exam did not appear")
        tap("conversion.row.sub-sub-1", in: app)

        XCTAssertTrue(element("conversion.review", in: app).waitForExistence(timeout: Timeout.content),
                      "The review screen did not appear")
        // K28: the exam's list title is pre-filled from the server's suggestion, next to the original title.
        XCTAssertTrue(reveal("conversion.review.title", in: app))
        XCTAssertEqual(element("conversion.review.title", in: app).label, "2023 VİZE")
        XCTAssertTrue(element("conversion.review.title.original", in: app).exists, "The original title is missing")
        // The draft list is long and lazy, so scroll until the publish button is built.
        let publish = element("conversion.review.publish", in: app)
        for _ in 0..<15 where !publish.exists { app.swipeUp() }
        tap("conversion.review.publish", in: app)

        let confirm = app.alerts.buttons["Yayınla"]
        XCTAssertTrue(confirm.waitForExistence(timeout: Timeout.transition), "The publish confirmation did not appear")
        confirm.tap()

        let done = app.alerts.buttons["Tamam"]
        XCTAssertTrue(done.waitForExistence(timeout: Timeout.content), "The publish result did not appear")
        done.tap()

        let row = element("conversion.row.sub-sub-1", in: app)
        XCTAssertTrue(element("conversion.row.sub-sub-2", in: app).waitForExistence(timeout: Timeout.content),
                      "The ready list did not come back")
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: row)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: Timeout.content), .completed, "The published exam stayed in the ready list")
    }

    @MainActor
    func testUnrecognisedTitleBlocksPublishingUntilANameIsPicked() {
        let app = launchApp(admin: true)

        tap("toolbar.account", in: app)
        tap("account.moderation", in: app)
        tap("moderation.ready", in: app)
        tap("conversion.row.sub-sub-2", in: app)
        XCTAssertTrue(element("conversion.review", in: app).waitForExistence(timeout: Timeout.content),
                      "The review screen did not appear")

        // "2021 DERS NOTU" matches no list name (K28): no suggestion, and "Yayınla" stays disabled.
        XCTAssertTrue(reveal("conversion.review.title", in: app))
        XCTAssertEqual(element("conversion.review.title", in: app).label, "Listeden bir ad seç")
        let publish = element("conversion.review.publish", in: app)
        for _ in 0..<15 where !publish.exists { app.swipeUp() }
        XCTAssertTrue(publish.exists, "The publish button did not appear")
        XCTAssertFalse(publish.isEnabled, "Publishing was allowed without a list name")

        for _ in 0..<15 where !element("conversion.review.title.name", in: app).isHittable { app.swipeDown() }
        tap("conversion.review.title.name", in: app)
        // The menu lists the names in the list's order; "FİNAL" is near the top, so it is on screen.
        let option = app.buttons["FİNAL"].firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: Timeout.transition), "The list names did not appear")
        option.tap()
        tap("conversion.review.title.year", in: app)
        app.typeText("2021")
        XCTAssertEqual(element("conversion.review.title", in: app).label, "2021 FİNAL")

        for _ in 0..<15 where !publish.isHittable { app.swipeUp() }
        XCTAssertTrue(publish.isEnabled, "Publishing stayed disabled after a name was picked")
        tap("conversion.review.publish", in: app)
        let confirm = app.alerts.buttons["Yayınla"]
        XCTAssertTrue(confirm.waitForExistence(timeout: Timeout.transition), "The publish confirmation did not appear")
        confirm.tap()
        XCTAssertTrue(app.alerts.buttons["Tamam"].waitForExistence(timeout: Timeout.content), "The publish result did not appear")
    }

    @MainActor
    func testRegeneratingAQuestionShowsItsProgress() {
        let app = launchApp(admin: true)

        tap("toolbar.account", in: app)
        tap("account.moderation", in: app)
        tap("moderation.ready", in: app)
        tap("conversion.row.sub-sub-1", in: app)
        XCTAssertTrue(element("conversion.review", in: app).waitForExistence(timeout: Timeout.content),
                      "The review screen did not appear")

        tap("conversion.question.regenerate.1", in: app)
        tap("ai.provider.claude", in: app)

        XCTAssertTrue(element("conversion.review.regenerating.1", in: app).waitForExistence(timeout: Timeout.content),
                      "The regenerating state did not appear")
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

    /// Waits for `identifier`, scrolling the (lazily built) form until it exists.
    @MainActor
    @discardableResult
    private func reveal(_ identifier: String, in app: XCUIApplication) -> Bool {
        let target = element(identifier, in: app)
        if target.waitForExistence(timeout: Timeout.transition) { return true }
        for _ in 0..<5 where !target.exists { app.swipeUp() }
        return target.exists
    }

    @MainActor
    private func tap(_ identifier: String, in app: XCUIApplication) {
        let target = element(identifier, in: app)
        XCTAssertTrue(reveal(identifier, in: app), "\(identifier) did not appear")
        for _ in 0..<5 where !target.isHittable { app.swipeUp() }
        target.tap()
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}

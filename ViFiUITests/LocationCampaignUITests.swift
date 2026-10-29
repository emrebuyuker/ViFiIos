import XCTest

/// Location campaigns on the bundled mock data (`-ViFiMockData`): the admin picks a place for a notification (the
/// mock picker stands in for the Google map), and the inbox's "Konuma Git" offers the two maps apps.
///
/// `nonisolated` because `XCTestCase`'s initializers are; the tests drive the UI on the main actor.
nonisolated final class LocationCampaignUITests: XCTestCase {
    private enum Timeout {
        static let transition: TimeInterval = 5
        static let content: TimeInterval = 15
    }

    private static let sampleName = "ViFi Öğrenci Kafesi"

    // MARK: - Composer

    @MainActor
    func testAdminAttachesAPlaceAndSendsACampaignAfterConfirming() {
        let app = launchApp(extra: ["-ViFiAdmin"])
        openComposer(in: app)
        compose(title: "Konum kampanyasi", body: "Kampuse yakin firsat.", in: app)

        choose("Konum", from: "notificationComposer.action", in: app)
        // Chosen, but no place yet: sending is blocked and the form says so.
        XCTAssertTrue(reveal("notificationComposer.location.note", in: app).exists, "The campaign-only note is missing")
        XCTAssertFalse(reveal("notificationComposer.send", in: app).isEnabled, "Send must wait for a place")
        // The note sits just above the send button (matched by its text: its icon shares the identifier).
        XCTAssertTrue(app.staticTexts["Haritadan geçerli bir konum seç."].waitForExistence(timeout: Timeout.transition),
                      "The missing place was not flagged")

        tap("notificationComposer.location.pick", in: app)
        tap("locationPicker.confirm", in: app)

        let summary = reveal("notificationComposer.location.summary", in: app)
        XCTAssertTrue(summary.label.contains(Self.sampleName), "The chosen place is not shown: \(summary.label)")
        XCTAssertTrue(reveal("notificationComposer.send", in: app).isEnabled, "Send should be ready once a place is chosen")

        tap("notificationComposer.send", in: app)
        let confirm = element("notificationComposer.confirm", in: app)
        XCTAssertTrue(confirm.waitForExistence(timeout: Timeout.transition), "The confirmation did not appear")
        confirm.tap()
        expectSuccess(in: app)

        // It was sent as a campaign even though the kind was left on "Duyuru".
        tap("notificationComposer.history", in: app)
        let row = historyRow(containing: "Konum kampanyasi", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: Timeout.content), "The sent notification is not in the history")
        XCTAssertTrue(row.label.contains("Kampanya"), "A location notification must be a campaign: \(row.label)")
    }

    @MainActor
    func testCancelingThePickerLeavesNoPlace() {
        let app = launchApp(extra: ["-ViFiAdmin"])
        openComposer(in: app)
        choose("Konum", from: "notificationComposer.action", in: app)

        tap("notificationComposer.location.pick", in: app)
        tap("locationPicker.cancel", in: app)

        XCTAssertTrue(element("notificationComposer.location.pick", in: app).waitForExistence(timeout: Timeout.transition))
        XCTAssertFalse(element("notificationComposer.location.summary", in: app).exists, "Canceling must not choose a place")
    }

    // MARK: - Inbox

    @MainActor
    func testKonumaGitOffersBothMapsApps() {
        let app = launchApp()
        openInbox(in: app)

        tap("inbox.row.p-location.action", in: app)

        XCTAssertTrue(element("inbox.location.google", in: app).waitForExistence(timeout: Timeout.transition),
                      "Google Haritalar was not offered")
        XCTAssertTrue(element("inbox.location.apple", in: app).exists, "Apple Haritalar was not offered")
    }

    @MainActor
    func testTappingTheCardOffersBothMapsApps() {
        let app = launchApp()
        openInbox(in: app)

        tap("inbox.row.p-location", in: app)

        XCTAssertTrue(element("inbox.location.google", in: app).waitForExistence(timeout: Timeout.transition),
                      "The card tap did not offer Google Haritalar")
        XCTAssertTrue(element("inbox.location.apple", in: app).exists, "The card tap did not offer Apple Haritalar")
    }

    @MainActor
    func testDecliningTheChoiceClosesItAndKeepsTheInbox() {
        let app = launchApp()
        openInbox(in: app)
        tap("inbox.row.p-location.action", in: app)
        XCTAssertTrue(element("inbox.location.google", in: app).waitForExistence(timeout: Timeout.transition))

        tap("inbox.location.cancel", in: app)

        XCTAssertTrue(element("inbox.location.google", in: app).waitForNonExistence(timeout: Timeout.transition),
                      "The choice should have closed")
        XCTAssertTrue(element("inbox.list", in: app).exists, "The inbox should still be open")
    }

    // MARK: - Helpers

    @MainActor
    private func launchApp(extra: [String] = []) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ViFiMockData"] + extra
        app.launch()
        XCTAssertTrue(element("home.list", in: app).waitForExistence(timeout: Timeout.content), "The home list did not appear")
        return app
    }

    @MainActor
    private func openInbox(in app: XCUIApplication) {
        tap("toolbar.inbox", in: app)
        XCTAssertTrue(element("inbox.list", in: app).waitForExistence(timeout: Timeout.transition), "The inbox did not open")
    }

    @MainActor
    private func openComposer(in app: XCUIApplication) {
        tap("toolbar.account", in: app)
        tap("account.notificationComposer", in: app)
        XCTAssertTrue(element("notificationComposer.title", in: app).waitForExistence(timeout: Timeout.content),
                      "The composer did not appear")
        XCTAssertTrue(element("notificationComposer.estimate", in: app).waitForExistence(timeout: Timeout.content),
                      "The audience estimate did not appear")
    }

    /// Fills the message first and the title last: Return on the single-line title also closes the keyboard, which
    /// would otherwise cover the buttons below.
    @MainActor
    private func compose(title: String, body: String, in app: XCUIApplication) {
        let bodyField = element("notificationComposer.body", in: app)
        XCTAssertTrue(bodyField.waitForExistence(timeout: Timeout.transition))
        bodyField.tap()
        bodyField.typeText(body)

        let titleField = element("notificationComposer.title", in: app)
        titleField.tap()
        titleField.typeText(title + "\n")
    }

    /// Opens a menu picker and picks one of its options by label.
    @MainActor
    private func choose(_ option: String, from picker: String, in app: XCUIApplication) {
        tap(picker, in: app)
        let item = app.buttons[option]
        XCTAssertTrue(item.waitForExistence(timeout: Timeout.transition), "\(option) was not offered by \(picker)")
        item.tap()
    }

    @MainActor
    private func historyRow(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH 'notificationComposer.history.row.' AND NOT identifier ENDSWITH '.cancel' "
                    + "AND label CONTAINS %@",
                text
            )
        ).firstMatch
    }

    /// The success note sits above the send button, so after a send it may be scrolled out of view.
    @MainActor
    private func expectSuccess(in app: XCUIApplication) {
        let success = element("notificationComposer.success", in: app)
        if !success.waitForExistence(timeout: Timeout.transition) {
            _ = reveal("notificationComposer.success", in: app)
        }
        XCTAssertTrue(success.exists, "The send was not confirmed")
    }

    /// Scrolls until the element is on screen (rows below the fold are not rendered, so they do not exist for the
    /// accessibility hierarchy until scrolled to), and fails when it never gets there.
    @MainActor
    private func reveal(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let target = element(identifier, in: app)
        for step in 0..<12 where !(target.exists && target.isHittable) {
            if step < 4 { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(target.waitForExistence(timeout: Timeout.transition), "\(identifier) did not appear")
        return target
    }

    @MainActor
    private func tap(_ identifier: String, in app: XCUIApplication) {
        reveal(identifier, in: app).tap()
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}

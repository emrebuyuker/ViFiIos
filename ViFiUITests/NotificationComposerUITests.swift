import XCTest

/// The admin "Bildirim Gönder" flow on the bundled mock data (`-ViFiMockData -ViFiAdmin`): the account entry shown
/// only to admins, the cascading audience pickers and their reach estimate, sending with a confirmation, and the
/// history (including canceling a scheduled one).
nonisolated final class NotificationComposerUITests: XCTestCase {
    private enum Timeout {
        static let transition: TimeInterval = 5
        static let content: TimeInterval = 15
    }

    private static let historyRowPrefix = "notificationComposer.history.row."

    @MainActor
    func testEntryIsHiddenFromNonAdmins() {
        let app = launchApp(admin: false)

        tap("toolbar.account", in: app)

        XCTAssertTrue(element("account.coinBalance", in: app).waitForExistence(timeout: Timeout.content))
        XCTAssertFalse(element("account.notificationComposer", in: app).exists, "The composer was shown to a non-admin")
    }

    @MainActor
    func testSegmentCascadeNarrowsTheEstimate() {
        let app = launchApp(admin: true)
        openComposer(in: app)

        // Everyone: all registered profiles in the sample data.
        expectEstimate("64", in: app)

        element("notificationComposer.audience", in: app).buttons["Belirli kitle"].tap()
        XCTAssertTrue(element("notificationComposer.university", in: app).waitForExistence(timeout: Timeout.transition))
        XCTAssertFalse(element("notificationComposer.faculty", in: app).isEnabled, "Faculty needs a university first")

        choose("Boğaziçi Üniversitesi · 40 kişi", from: "notificationComposer.university", in: app)
        expectEstimate("40", in: app)

        choose("Mühendislik Fakültesi · 28 kişi", from: "notificationComposer.faculty", in: app)
        expectEstimate("28", in: app)

        choose("Bilgisayar Mühendisliği · 17 kişi", from: "notificationComposer.department", in: app)
        expectEstimate("17", in: app)

        // A new university resets the levels below it and the department list closes again.
        choose("Sakarya Üniversitesi · 24 kişi", from: "notificationComposer.university", in: app)
        expectEstimate("24", in: app)
        XCTAssertFalse(element("notificationComposer.department", in: app).isEnabled, "The department was not reset")

        element("notificationComposer.gender", in: app).buttons["Kadın"].tap()
        expectEstimate("9", in: app)
    }

    @MainActor
    func testAdminSendsAnAnnouncementAfterConfirming() {
        let app = launchApp(admin: true)
        openComposer(in: app)
        compose(title: "UI test duyurusu", body: "Bu bir deneme mesajidir.", in: app)

        tap("notificationComposer.send", in: app)
        let confirm = element("notificationComposer.confirm", in: app)
        XCTAssertTrue(confirm.waitForExistence(timeout: Timeout.transition), "The confirmation did not appear")
        confirm.tap()

        expectSuccess(in: app)

        // The form is ready for the next one, and the history lists what was just sent.
        tap("notificationComposer.history", in: app)
        let row = historyRow(containing: "UI test duyurusu", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: Timeout.content), "The sent notification is not in the history")
        XCTAssertTrue(row.label.contains("Gönderildi"), "The row does not show it as sent: \(row.label)")
    }

    @MainActor
    func testDecliningTheConfirmationSendsNothing() {
        let app = launchApp(admin: true)
        openComposer(in: app)
        compose(title: "Vazgecilen duyuru", body: "Gonderilmeyecek.", in: app)

        tap("notificationComposer.send", in: app)
        let cancel = element("notificationComposer.confirm.cancel", in: app)
        XCTAssertTrue(cancel.waitForExistence(timeout: Timeout.transition), "The confirmation did not appear")
        cancel.tap()

        XCTAssertFalse(element("notificationComposer.success", in: app).exists)
        tap("notificationComposer.history", in: app)
        XCTAssertTrue(element("notificationComposer.history.list", in: app).waitForExistence(timeout: Timeout.content))
        XCTAssertFalse(historyRow(containing: "Vazgecilen duyuru", in: app).exists, "A declined send reached the history")
    }

    @MainActor
    func testScheduledNotificationIsCanceledFromHistory() {
        let app = launchApp(admin: true)
        openComposer(in: app)
        compose(title: "Zamanli duyuru", body: "Yarin gider.", in: app)
        // The switch is the control inside the row; tapping the row's middle would hit its label.
        reveal("notificationComposer.scheduleToggle", in: app).switches.firstMatch.tap()
        _ = reveal("notificationComposer.scheduledAt", in: app)

        tap("notificationComposer.send", in: app)
        let confirm = element("notificationComposer.confirm", in: app)
        XCTAssertTrue(confirm.waitForExistence(timeout: Timeout.transition), "The confirmation did not appear")
        confirm.tap()
        expectSuccess(in: app)

        tap("notificationComposer.history", in: app)
        let row = historyRow(containing: "Zamanli duyuru", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: Timeout.content), "The scheduled notification is not in the history")
        XCTAssertTrue(row.label.contains("Zamanlandı"), "The row does not show it as scheduled: \(row.label)")

        row.swipeLeft()
        let cancel = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH '.cancel'", Self.historyRowPrefix)
        ).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: Timeout.transition), "The cancel action did not appear")
        cancel.tap()

        let canceled = historyRow(containing: "İptal edildi", in: app)
        XCTAssertTrue(canceled.waitForExistence(timeout: Timeout.content), "The notification was not canceled")
    }

    @MainActor
    func testAdminLinksAnExamPickedFromTheArchive() {
        let app = launchApp(admin: true)
        openComposer(in: app)
        compose(title: "Sinav bildirimi", body: "Yeni sinav eklendi.", in: app)
        // The image picker is offered (the photo library itself is a system UI the tests do not drive).
        XCTAssertTrue(reveal("notificationComposer.imagePicker", in: app).exists)

        choose("Sınav", from: "notificationComposer.action", in: app)
        tap("notificationComposer.exam", in: app)
        for name in ["BOZOK ÜNİVERSİTESİ", "MÜHENDİSLİK MİMARLIK FAKÜLTESİ", "BİLGİSAYAR MÜHENDİSLİĞİ", "MÜHENDİSLİK MATEMATİĞİ", "2019 FİNAL"] {
            let row = element("notificationComposer.exam.row.\(name)", in: app)
            XCTAssertTrue(row.waitForExistence(timeout: Timeout.content), "\(name) is not offered by the exam picker")
            row.tap()
        }

        let path = reveal("notificationComposer.examPath", in: app)
        XCTAssertTrue(path.label.contains("MÜHENDİSLİK MATEMATİĞİ"), "The picked exam's place is not shown: \(path.label)")
        XCTAssertTrue(element("notificationComposer.exam", in: app).label.contains("2019 FİNAL"))

        tap("notificationComposer.send", in: app)
        let confirm = element("notificationComposer.confirm", in: app)
        XCTAssertTrue(confirm.waitForExistence(timeout: Timeout.transition), "The confirmation did not appear")
        confirm.tap()
        expectSuccess(in: app)
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
    private func openComposer(in app: XCUIApplication) {
        tap("toolbar.account", in: app)
        tap("account.notificationComposer", in: app)
        XCTAssertTrue(element("notificationComposer.title", in: app).waitForExistence(timeout: Timeout.content),
                      "The composer did not appear")
        // The audience facets arrive from the (mock) service.
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
    private func expectEstimate(_ count: String, in app: XCUIApplication) {
        let estimate = element("notificationComposer.estimate", in: app)
        let predicate = NSPredicate(format: "label CONTAINS %@", "≈ \(count) kişi")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: estimate)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: Timeout.transition), .completed,
                       "The estimate should read \(count), reads: \(estimate.label)")
    }

    @MainActor
    private func historyRow(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND NOT identifier ENDSWITH '.cancel' AND label CONTAINS %@",
                Self.historyRowPrefix, text
            )
        ).firstMatch
    }

    /// Scrolls the form until the element is on screen (rows below the fold are not rendered at all, so they do not
    /// exist for the accessibility hierarchy until scrolled to), and fails when it never gets there.
    @MainActor
    private func reveal(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        let target = element(identifier, in: app)
        // Mostly downwards in the form (the controls are below the fold), then back up for anything above.
        for step in 0..<12 where !(target.exists && target.isHittable) {
            if step < 4 { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(target.waitForExistence(timeout: Timeout.transition), "\(identifier) did not appear")
        return target
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

    @MainActor
    private func tap(_ identifier: String, in app: XCUIApplication) {
        reveal(identifier, in: app).tap()
    }

    @MainActor
    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}

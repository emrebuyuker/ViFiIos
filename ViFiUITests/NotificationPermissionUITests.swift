import XCTest

/// The notification permission flow and its settings on the bundled mock data (`-ViFiMockData`): step 1/2 (the OS
/// permission) leading to step 2/2 (the campaign consent), Account › Bildirim Ayarları with the live campaign
/// switch, and the contextual re-ask of the consent in the inbox. The mock keeps the OS permission and the consent
/// in memory, so what one screen writes the others show.
///
/// `nonisolated` because `XCTestCase`'s initializers are; the tests drive the UI on the main actor.
nonisolated final class NotificationPermissionUITests: XCTestCase {
    private enum Timeout {
        static let transition: TimeInterval = 5
        static let content: TimeInterval = 15
    }

    // MARK: - The flow

    @MainActor
    func testEnablingThenAcceptingTheConsentTurnsCampaignsOn() {
        let app = launchApp(extra: ["-ViFiNotificationsPrompt"])
        XCTAssertTrue(app.element("notifications.priming").waitForExistence(timeout: Timeout.content),
                      "Step 1/2 did not appear")

        tap("notifications.priming.enable", in: app)

        XCTAssertTrue(app.element("notifications.consent").waitForExistence(timeout: Timeout.transition),
                      "Step 2/2 did not follow the permission")
        XCTAssertTrue(app.element("notifications.consent.accept").exists)
        XCTAssertTrue(app.element("notifications.consent.decline").exists)

        tap("notifications.consent.accept", in: app)

        XCTAssertTrue(app.element("notifications.consent").waitForNonExistence(timeout: Timeout.transition),
                      "The flow should close after the answer")
        openNotificationSettings(in: app)
        XCTAssertEqual(marketingSwitch(in: app).value as? String, "1", "Campaigns should be on after \"Evet\"")
        XCTAssertTrue(app.element("notificationSettings.permission").label.contains("Açık"))
    }

    @MainActor
    func testEnablingThenDecliningTheConsentKeepsCampaignsOff() {
        let app = launchApp(extra: ["-ViFiNotificationsPrompt"])
        XCTAssertTrue(app.element("notifications.priming").waitForExistence(timeout: Timeout.content))
        tap("notifications.priming.enable", in: app)
        XCTAssertTrue(app.element("notifications.consent").waitForExistence(timeout: Timeout.transition))

        tap("notifications.consent.decline", in: app)

        XCTAssertTrue(app.element("notifications.consent").waitForNonExistence(timeout: Timeout.transition))
        openNotificationSettings(in: app)
        XCTAssertEqual(marketingSwitch(in: app).value as? String, "0", "Campaigns should stay off after \"Hayır\"")
        XCTAssertTrue(app.element("notificationSettings.permission").label.contains("Açık"))
    }

    @MainActor
    func testNotNowClosesThePromptAndLeavesNotificationsQuiet() {
        let app = launchApp(extra: ["-ViFiNotificationsPrompt"])
        XCTAssertTrue(app.element("notifications.priming").waitForExistence(timeout: Timeout.content))

        tap("notifications.priming.dismiss", in: app)

        XCTAssertTrue(app.element("notifications.priming").waitForNonExistence(timeout: Timeout.transition))
        XCTAssertFalse(app.element("notifications.consent").exists, "No consent is asked without the permission")
        openNotificationSettings(in: app)
        // Provisional authorization was granted silently at launch: quiet, with a way to turn it fully on.
        XCTAssertTrue(app.element("notificationSettings.permission").label.contains("Sessiz"))
        XCTAssertTrue(app.element("notificationSettings.enable").exists)
        XCTAssertEqual(marketingSwitch(in: app).value as? String, "0")
    }

    @MainActor
    func testPromptWaitsForTheOnboardingTourToEnd() {
        let app = launchApp(extra: ["-ViFiNotificationsPrompt", "-ViFiShowOnboarding"], waitForHome: false)
        XCTAssertTrue(app.element("onboarding.pager").waitForExistence(timeout: Timeout.content))
        XCTAssertFalse(app.element("notifications.priming").exists, "The permission is not asked over the tour")

        tap("onboarding.skip", in: app)

        XCTAssertTrue(app.element("notifications.priming").waitForExistence(timeout: Timeout.content),
                      "The permission step should follow the tour")
    }

    @MainActor
    func testConsentPageCannotBeSwipedAway() {
        let app = launchApp(extra: ["-ViFiNotificationsPrompt"])
        XCTAssertTrue(app.element("notifications.priming").waitForExistence(timeout: Timeout.content))
        tap("notifications.priming.enable", in: app)
        XCTAssertTrue(app.element("notifications.consent").waitForExistence(timeout: Timeout.transition))

        app.element("notifications.consent").swipeDown()

        XCTAssertTrue(app.element("notifications.consent").exists, "The consent is answered, not swiped away")
    }

    // MARK: - Account › Bildirim Ayarları

    @MainActor
    func testCampaignSwitchTurnsOnAndOffAndKeepsItsValue() {
        let app = launchApp()
        openNotificationSettings(in: app)
        XCTAssertEqual(marketingSwitch(in: app).value as? String, "0", "Campaigns are off until the user opts in")
        XCTAssertTrue(app.element("notificationSettings.permission").label.contains("Açık"))

        toggleMarketing(in: app)
        XCTAssertEqual(marketingSwitch(in: app).value as? String, "1")

        // Leaving the screen and coming back shows the stored answer.
        app.navigationBars["Bildirim Ayarları"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.element("account.sheet").waitForExistence(timeout: Timeout.transition))
        tap("account.notificationSettings", in: app)
        XCTAssertEqual(marketingSwitch(in: app).value as? String, "1")

        toggleMarketing(in: app)
        XCTAssertEqual(marketingSwitch(in: app).value as? String, "0")
    }

    @MainActor
    func testDeniedPermissionSendsTheUserToSettings() {
        let app = launchApp(extra: ["-ViFiNotificationsDenied"])

        openNotificationSettings(in: app)

        XCTAssertTrue(app.element("notificationSettings.permission").label.contains("Kapalı"))
        XCTAssertTrue(app.element("notificationSettings.openSettings").exists)
        XCTAssertFalse(app.element("notificationSettings.enable").exists, "The system will not ask again")
    }

    // MARK: - Re-ask of the consent

    @MainActor
    func testInboxOffersTheConsentOnceMoreAfterANo() {
        let app = launchApp(extra: ["-ViFiConsentReask"])
        tap("toolbar.inbox", in: app)

        XCTAssertTrue(app.element("notifications.consent").waitForExistence(timeout: Timeout.content),
                      "The inbox should offer the consent once more")

        tap("notifications.consent.decline", in: app)
        XCTAssertTrue(app.element("notifications.consent").waitForNonExistence(timeout: Timeout.transition))
        XCTAssertTrue(app.element("inbox.list").exists, "The inbox stays open under the offer")

        // It is offered only once: opening the inbox again shows nothing.
        tap("inbox.done", in: app)
        XCTAssertTrue(app.element("inbox.list").waitForNonExistence(timeout: Timeout.transition))
        tap("toolbar.inbox", in: app)
        XCTAssertTrue(app.element("inbox.list").waitForExistence(timeout: Timeout.transition))
        sleep(2)
        XCTAssertFalse(app.element("notifications.consent").exists, "The re-ask must not repeat")
    }

    @MainActor
    func testAcceptingTheInboxReaskTurnsCampaignsOn() {
        let app = launchApp(extra: ["-ViFiConsentReask"])
        tap("toolbar.inbox", in: app)
        XCTAssertTrue(app.element("notifications.consent").waitForExistence(timeout: Timeout.content))

        tap("notifications.consent.accept", in: app)
        XCTAssertTrue(app.element("notifications.consent").waitForNonExistence(timeout: Timeout.transition))
        tap("inbox.done", in: app)

        openNotificationSettings(in: app)
        XCTAssertEqual(marketingSwitch(in: app).value as? String, "1")
    }

    // MARK: - Helpers

    @MainActor
    private func launchApp(extra: [String] = [], waitForHome: Bool = true) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ViFiMockData"] + extra
        app.launch()
        if waitForHome {
            XCTAssertTrue(app.element("home.list").waitForExistence(timeout: Timeout.content), "The home list did not appear")
        }
        return app
    }

    /// Home → Hesap → Bildirim Ayarları.
    @MainActor
    private func openNotificationSettings(in app: XCUIApplication) {
        tap("toolbar.account", in: app)
        XCTAssertTrue(app.element("account.sheet").waitForExistence(timeout: Timeout.transition))
        tap("account.notificationSettings", in: app)
        XCTAssertTrue(app.element("notificationSettings.list").waitForExistence(timeout: Timeout.transition),
                      "The notification settings did not open")
        // The permission row is read from the system asynchronously.
        let permission = app.element("notificationSettings.permission")
        XCTAssertTrue(permission.waitForExistence(timeout: Timeout.transition))
        XCTAssertTrue(marketingSwitch(in: app).waitForExistence(timeout: Timeout.transition))
    }

    @MainActor
    private func marketingSwitch(in app: XCUIApplication) -> XCUIElement {
        let toggle = app.switches["notificationSettings.marketing"]
        XCTAssertTrue(toggle.waitForExistence(timeout: Timeout.transition), "The campaign switch did not appear")
        return toggle
    }

    /// Flips the campaign switch, tapping its control at the trailing edge of the row.
    @MainActor
    private func toggleMarketing(in app: XCUIApplication) {
        let toggle = marketingSwitch(in: app)
        let before = toggle.value as? String
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let changed = NSPredicate(format: "value != %@", before ?? "")
        expectation(for: changed, evaluatedWith: toggle)
        waitForExpectations(timeout: Timeout.transition)
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

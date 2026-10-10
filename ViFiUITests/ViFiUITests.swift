import XCTest

/// End-to-end flows on the bundled mock archive (`-ViFiMockData`): no Firebase, no network,
/// and an empty recents list on every launch.
///
/// `nonisolated` because `XCTestCase`'s initializers are; the tests themselves drive the UI on the main actor.
nonisolated final class ViFiUITests: XCTestCase {
    // MARK: - Browsing

    @MainActor
    func testBrowsingToImageExamShowsPagesAndFullScreenViewer() {
        let app = launchApp()

        openRows(MockArchive.engineeringMathematics + ["2019 FİNAL"], in: app)

        XCTAssertTrue(app.element("exam.images").waitForExistence(timeout: Timeout.content))
        let firstPage = app.element("exam.page.0")
        XCTAssertTrue(firstPage.waitForExistence(timeout: Timeout.content))

        firstPage.tap()

        let viewer = app.element("viewer.fullscreen")
        XCTAssertTrue(viewer.waitForExistence(timeout: Timeout.transition))
        let counter = app.element("viewer.counter")
        XCTAssertTrue(counter.waitForExistence(timeout: Timeout.transition))
        XCTAssertEqual(counter.label, "1 / 3")

        app.element("viewer.close").tap()

        XCTAssertTrue(viewer.waitForNonExistence(timeout: Timeout.transition))
        XCTAssertTrue(firstPage.exists)
    }

    @MainActor
    func testBrowsingToPDFExamShowsDocument() {
        let app = launchApp()

        openRows(MockArchive.engineeringMathematics + ["2018 VİZE"], in: app)

        XCTAssertTrue(app.element("exam.pdf").waitForExistence(timeout: Timeout.content))
        XCTAssertFalse(app.element("state.error").exists)
    }

    @MainActor
    func testLessonWithoutExamsShowsEmptyState() {
        let app = launchApp()

        openRows(["KOCAELİ ÜNİVERSİTESİ", "MÜHENDİSLİK FAKÜLTESİ", "MATEMATİK BÖLÜMÜ", "TOPOLOJİ 2"], in: app)

        XCTAssertTrue(app.element("state.empty").waitForExistence(timeout: Timeout.content))
    }

    @MainActor
    func testExamWithoutFilesCannotBeOpened() {
        let app = launchApp()
        openRows(["SAKARYA ÜNİVERSİTESİ", "İŞLETME FAKÜLTESİ", "İŞLETME BÖLÜMÜ", "MUHASEBE"], in: app)

        let row = app.buttons["row.2021 VİZE"]
        XCTAssertTrue(row.waitForExistence(timeout: Timeout.content))
        XCTAssertFalse(row.isEnabled)

        row.tap()

        XCTAssertFalse(app.element("exam.images").waitForExistence(timeout: Timeout.transition))
        XCTAssertFalse(app.element("exam.pdf").exists)
        XCTAssertTrue(app.element("breadcrumb.4").exists, "The lesson list should still be on screen")
    }

    // MARK: - Navigation shortcuts

    @MainActor
    func testRootBreadcrumbReturnsHome() {
        let app = launchApp()
        openRows(Array(MockArchive.engineeringMathematics.prefix(3)), in: app)
        XCTAssertTrue(app.element("row.MÜHENDİSLİK MATEMATİĞİ").waitForExistence(timeout: Timeout.content))

        tapBreadcrumb(0, onListAtDepth: 3, in: app)

        XCTAssertTrue(app.element("home.list").waitForExistence(timeout: Timeout.transition))
        XCTAssertTrue(app.element("row.BOZOK ÜNİVERSİTESİ").waitForExistence(timeout: Timeout.transition))
        XCTAssertTrue(app.element("browse.list").waitForNonExistence(timeout: Timeout.transition))
    }

    @MainActor
    func testBreadcrumbReturnsToAncestorList() {
        let app = launchApp()
        openRows(Array(MockArchive.engineeringMathematics.prefix(3)), in: app)
        XCTAssertTrue(app.element("row.MÜHENDİSLİK MATEMATİĞİ").waitForExistence(timeout: Timeout.content))

        tapBreadcrumb(1, onListAtDepth: 3, in: app)

        XCTAssertTrue(app.element("row.MÜHENDİSLİK MİMARLIK FAKÜLTESİ").waitForExistence(timeout: Timeout.transition))
        XCTAssertTrue(app.element("breadcrumb.2").waitForNonExistence(timeout: Timeout.transition))
    }

    @MainActor
    func testHomeToolbarButtonReturnsHome() {
        let app = launchApp()
        openRows(MockArchive.engineeringMathematics, in: app)
        XCTAssertTrue(app.element("row.2019 FİNAL").waitForExistence(timeout: Timeout.content))

        tapElement("toolbar.home", in: app)

        XCTAssertTrue(app.element("home.list").waitForExistence(timeout: Timeout.transition))
        XCTAssertTrue(app.element("browse.list").waitForNonExistence(timeout: Timeout.transition))
    }

    // MARK: - Recents

    @MainActor
    func testOpenedExamAppearsInRecentsAndReopensWithItsHierarchy() {
        let app = launchApp()
        XCTAssertFalse(app.element("home.recents").exists, "Recents should start empty with mock data")

        openRows(MockArchive.engineeringMathematics + ["2019 FİNAL"], in: app)
        XCTAssertTrue(app.element("exam.page.0").waitForExistence(timeout: Timeout.content))
        goBack(in: app)
        tapElement("toolbar.home", in: app)

        XCTAssertTrue(app.element("home.recents").waitForExistence(timeout: Timeout.transition))
        let card = app.element("recent.2019 FİNAL")
        XCTAssertTrue(card.waitForExistence(timeout: Timeout.transition))

        card.tap()

        XCTAssertTrue(app.element("exam.page.0").waitForExistence(timeout: Timeout.content))
        goBack(in: app)
        XCTAssertTrue(app.element("row.2019 FİNAL").waitForExistence(timeout: Timeout.content))
        XCTAssertTrue(app.element("breadcrumb.4").exists, "Back from a recent exam should land on its lesson")
    }

    @MainActor
    func testClearingRecentsHidesTheShelf() {
        let app = launchApp()
        openRows(MockArchive.engineeringMathematics + ["2018 VİZE"], in: app)
        XCTAssertTrue(app.element("exam.pdf").waitForExistence(timeout: Timeout.content))
        goBack(in: app)
        tapElement("toolbar.home", in: app)
        let recents = app.element("home.recents")
        XCTAssertTrue(recents.waitForExistence(timeout: Timeout.transition))

        tapElement("home.recents.clear", in: app)
        let confirm = app.buttons.matching(
            NSPredicate(format: "identifier == %@ OR label == %@", "home.recents.clear.confirm", "Tümünü Temizle")
        ).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: Timeout.transition))
        confirm.tap()

        XCTAssertTrue(recents.waitForNonExistence(timeout: Timeout.transition))
    }

    // MARK: - Search

    @MainActor
    func testSearchFiltersUniversities() {
        let app = launchApp()
        XCTAssertTrue(app.element("row.BOZOK ÜNİVERSİTESİ").waitForExistence(timeout: Timeout.content))

        search("kocaeli", in: app)

        XCTAssertTrue(app.element("row.KOCAELİ ÜNİVERSİTESİ").waitForExistence(timeout: Timeout.transition))
        XCTAssertTrue(app.element("row.BOZOK ÜNİVERSİTESİ").waitForNonExistence(timeout: Timeout.transition))
        XCTAssertFalse(app.element("row.SAKARYA ÜNİVERSİTESİ").exists)
    }

    @MainActor
    func testSearchWithoutMatchesShowsNoResults() {
        let app = launchApp()
        XCTAssertTrue(app.element("row.BOZOK ÜNİVERSİTESİ").waitForExistence(timeout: Timeout.content))

        search("zzzz", in: app)

        XCTAssertTrue(app.element("state.noResults").waitForExistence(timeout: Timeout.transition))
        XCTAssertFalse(app.element("row.BOZOK ÜNİVERSİTESİ").exists)
    }

    // MARK: - Login

    @MainActor
    func testSignedOutLaunchShowsLoginInsteadOfTheArchive() {
        let app = launchSignedOutApp()

        XCTAssertTrue(app.element("login.phone").exists)
        XCTAssertFalse(app.element("home.list").exists)
        XCTAssertFalse(app.element("login.sendCode").isEnabled, "Sending needs a complete number")
    }

    @MainActor
    func testLoginWithPhoneNumberAndCodeOpensHome() {
        let app = launchSignedOutApp()

        enterPhoneNumber("05321234567", in: app)
        tapElement("login.sendCode", in: app)

        let codeField = app.element("login.code")
        XCTAssertTrue(codeField.waitForExistence(timeout: Timeout.content), "The code step did not appear")
        XCTAssertFalse(app.element("login.resend").isEnabled, "A new code has to wait for the cooldown")
        codeField.typeText("111111")

        XCTAssertTrue(app.element("home.list").waitForExistence(timeout: Timeout.content), "Home did not appear after signing in")
        XCTAssertTrue(app.element("login.phone").waitForNonExistence(timeout: Timeout.transition))
        XCTAssertTrue(app.element("row.BOZOK ÜNİVERSİTESİ").waitForExistence(timeout: Timeout.content))
    }

    @MainActor
    func testWrongCodeShowsErrorAndTheRightCodeStillWorks() {
        let app = launchSignedOutApp()
        enterPhoneNumber("5321234567", in: app)
        tapElement("login.sendCode", in: app)
        let codeField = app.element("login.code")
        XCTAssertTrue(codeField.waitForExistence(timeout: Timeout.content))

        codeField.typeText("000000")

        XCTAssertTrue(app.element("login.error").waitForExistence(timeout: Timeout.content), "No error for a wrong code")
        XCTAssertFalse(app.element("home.list").exists)

        codeField.typeText("111111")

        XCTAssertTrue(app.element("home.list").waitForExistence(timeout: Timeout.content))
    }

    @MainActor
    func testChangeNumberReturnsToNumberStep() {
        let app = launchSignedOutApp()
        enterPhoneNumber("5321234567", in: app)
        tapElement("login.sendCode", in: app)
        XCTAssertTrue(app.element("login.code").waitForExistence(timeout: Timeout.content))

        tapElement("login.changeNumber", in: app)

        XCTAssertTrue(app.element("login.phone").waitForExistence(timeout: Timeout.transition))
        XCTAssertTrue(app.element("login.code").waitForNonExistence(timeout: Timeout.transition))
        XCTAssertTrue(app.element("login.sendCode").isEnabled, "The typed number is kept for editing")
    }

    // MARK: - Account

    @MainActor
    func testAccountSheetShowsNumberAndSignOutReturnsToLogin() {
        let app = launchApp()

        tapElement("toolbar.account", in: app)

        XCTAssertTrue(app.element("account.sheet").waitForExistence(timeout: Timeout.transition))
        let phone = app.element("account.phone")
        XCTAssertTrue(phone.waitForExistence(timeout: Timeout.transition))
        XCTAssertTrue(phone.label.contains("532 123 45 67"), "The account should show the signed-in number, was \(phone.label)")

        tapElement("account.signOut", in: app)
        tapElement("account.signOut.confirm", in: app)

        XCTAssertTrue(app.element("login.phone").waitForExistence(timeout: Timeout.content), "Sign-out did not show the login screen")
        XCTAssertFalse(app.element("home.list").exists)
        XCTAssertFalse(app.element("account.sheet").exists)
    }

    @MainActor
    func testSignOutThenSignInStartsOnHome() {
        let app = launchApp()
        openRows(Array(MockArchive.engineeringMathematics.prefix(2)), in: app)
        XCTAssertTrue(app.element("row.BİLGİSAYAR MÜHENDİSLİĞİ").waitForExistence(timeout: Timeout.content))
        tapElement("toolbar.home", in: app)
        tapElement("toolbar.account", in: app)
        tapElement("account.signOut", in: app)
        tapElement("account.signOut.confirm", in: app)
        XCTAssertTrue(app.element("login.phone").waitForExistence(timeout: Timeout.content))

        enterPhoneNumber("5321234567", in: app)
        tapElement("login.sendCode", in: app)
        let codeField = app.element("login.code")
        XCTAssertTrue(codeField.waitForExistence(timeout: Timeout.content))
        codeField.typeText("111111")

        XCTAssertTrue(app.element("home.list").waitForExistence(timeout: Timeout.content))
        XCTAssertTrue(app.element("browse.list").waitForNonExistence(timeout: Timeout.transition))
    }

    @MainActor
    func testDeletingTheAccountReturnsToLogin() {
        let app = launchApp()
        tapElement("toolbar.account", in: app)
        tapElement("account.delete", in: app)

        tapElement("account.delete.confirm", in: app)

        XCTAssertTrue(app.element("login.phone").waitForExistence(timeout: Timeout.content), "Deleting did not show the login screen")
        XCTAssertFalse(app.element("home.list").exists)
    }

    @MainActor
    func testAccountSheetCloses() {
        let app = launchApp()
        tapElement("toolbar.account", in: app)
        XCTAssertTrue(app.element("account.sheet").waitForExistence(timeout: Timeout.transition))

        tapElement("account.done", in: app)

        XCTAssertTrue(app.element("account.sheet").waitForNonExistence(timeout: Timeout.transition))
        XCTAssertTrue(app.element("home.list").exists)
    }

    // MARK: - Update gate

    @MainActor
    func testRequiredUpdateBlocksTheAppWithAnUpdateButton() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ViFiMockData", "-ViFiForceUpdate"]
        app.launch()

        XCTAssertTrue(app.element("forceUpdate.title").waitForExistence(timeout: Timeout.content), "The force-update screen did not appear")
        let updateButton = app.element("forceUpdate.update")
        XCTAssertTrue(updateButton.waitForExistence(timeout: Timeout.transition), "The update button is missing")
        XCTAssertTrue(updateButton.isHittable, "The update button must be reachable on the blocking screen")
    }
}

// MARK: - Steps

@MainActor
private extension ViFiUITests {
    enum Timeout {
        /// Screen transitions and in-memory updates.
        static let transition: TimeInterval = 5
        /// Loading from the mock archive and decoding bundled files.
        static let content: TimeInterval = 15
    }

    enum MockArchive {
        /// University › faculty › department › lesson of the mock exams `2019 FİNAL` (JPG) and `2018 VİZE` (PDF).
        static let engineeringMathematics = [
            "BOZOK ÜNİVERSİTESİ",
            "MÜHENDİSLİK MİMARLIK FAKÜLTESİ",
            "BİLGİSAYAR MÜHENDİSLİĞİ",
            "MÜHENDİSLİK MATEMATİĞİ",
        ]
    }

    /// Launches the app on the bundled mock archive and waits for the home list.
    func launchApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ViFiMockData"]
        app.launch()
        XCTAssertTrue(app.element("home.list").waitForExistence(timeout: Timeout.content), "The home list did not appear")
        return app
    }

    /// Launches the app on the mock archive without a signed-in user and waits for the login screen.
    func launchSignedOutApp() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ViFiMockData", "-ViFiSignedOut"]
        app.launch()
        XCTAssertTrue(app.element("login.phone").waitForExistence(timeout: Timeout.content), "The login screen did not appear")
        return app
    }

    /// Types `number` into the login screen's number field.
    func enterPhoneNumber(_ number: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let field = app.element("login.phone")
        XCTAssertTrue(field.waitForExistence(timeout: Timeout.transition), "No number field", file: file, line: line)
        field.tap()
        field.typeText(number)
    }

    /// Taps the archive rows `row.<name>` one after another, drilling down the archive.
    func openRows(_ names: [String], in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        for name in names {
            let row = app.element("row.\(name)")
            XCTAssertTrue(row.waitForExistence(timeout: Timeout.content), "Row \(name) did not appear", file: file, line: line)
            scrollIntoView(row, in: app)
            row.tap()
        }
    }

    /// Waits for the element with `identifier`, then taps it.
    func tapElement(_ identifier: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let element = app.element(identifier)
        XCTAssertTrue(element.waitForExistence(timeout: Timeout.transition), "\(identifier) did not appear", file: file, line: line)
        element.tap()
    }

    /// Taps breadcrumb chip `index` on the list at `depth`.
    ///
    /// The trail keeps its last (current) chip in view, so it is swiped back towards its start first
    /// when the chip is scrolled out of sight.
    func tapBreadcrumb(
        _ index: Int,
        onListAtDepth depth: Int,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let currentChip = app.element("breadcrumb.\(depth)")
        XCTAssertTrue(currentChip.waitForExistence(timeout: Timeout.transition), "Breadcrumb \(depth) did not appear", file: file, line: line)
        let chip = app.element("breadcrumb.\(index)")
        for _ in 0..<3 where !chip.isHittable {
            currentChip.swipeRight()
        }
        chip.tap()
    }

    /// Taps the navigation bar's back button.
    func goBack(in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(backButton.waitForExistence(timeout: Timeout.transition), "No back button", file: file, line: line)
        backButton.tap()
    }

    /// Types `text` into the home screen's search field, revealing the field first if it is collapsed.
    func search(_ text: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let field = app.searchFields.firstMatch
        if !field.waitForExistence(timeout: Timeout.transition) {
            app.element("home.list").swipeDown()
        }
        XCTAssertTrue(field.waitForExistence(timeout: Timeout.transition), "No search field", file: file, line: line)
        field.tap()
        field.typeText(text)
    }

    /// Swipes the screen up until `element` can be tapped (lists only render rows near the screen).
    func scrollIntoView(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<5 where !element.isHittable {
            app.swipeUp()
        }
    }
}

private extension XCUIApplication {
    /// The first element with `identifier`, whatever its type.
    func element(_ identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}

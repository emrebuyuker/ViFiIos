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

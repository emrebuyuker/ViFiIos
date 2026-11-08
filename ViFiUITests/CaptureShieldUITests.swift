import XCTest

/// The Debug self-test (`-ViFiCaptureShieldSelfTest`) on every exam surface: the list card, the full-screen pager and
/// the PDF viewer publish `verified` on `exam.shield.selfTest` when the capture render leaves the page out.
/// `-ViFiCaptureShieldOff` is the negative control (`off`). A hierarchy / regression check, not device proof.
nonisolated final class CaptureShieldUITests: XCTestCase {
    private enum Timeout {
        static let content: TimeInterval = 15
        static let selfTest: TimeInterval = 10
    }

    private static let course = [
        "BOZOK ÜNİVERSİTESİ", "MÜHENDİSLİK MİMARLIK FAKÜLTESİ", "BİLGİSAYAR MÜHENDİSLİĞİ", "MÜHENDİSLİK MATEMATİĞİ",
    ]
    private static let imageExam = "2019 FİNAL"
    private static let pdfExam = "2018 VİZE"

    @MainActor
    func testListCardsAreVerified() {
        let app = launch(shieldOff: false)
        open(Self.course + [Self.imageExam], in: app)
        XCTAssertTrue(element(app, "exam.page.0").waitForExistence(timeout: Timeout.content))

        assertSelfTest(in: app, equals: "verified")
    }

    @MainActor
    func testPagerPageIsVerified() {
        let app = launch(shieldOff: false)
        open(Self.course + [Self.imageExam], in: app)
        let first = element(app, "exam.page.0")
        XCTAssertTrue(first.waitForExistence(timeout: Timeout.content))
        first.tap()
        XCTAssertTrue(element(app, "viewer.fullscreen").waitForExistence(timeout: Timeout.content))

        // The pager covers the list, so its own containers are the ones still on screen and measured last.
        assertSelfTest(in: app, equals: "verified")
    }

    @MainActor
    func testPDFIsVerified() {
        let app = launch(shieldOff: false)
        open(Self.course + [Self.pdfExam], in: app)
        XCTAssertTrue(element(app, "exam.pdf").waitForExistence(timeout: Timeout.content))

        assertSelfTest(in: app, equals: "verified")
    }

    @MainActor
    func testShieldOffIsReportedAsOff() {
        let app = launch(shieldOff: true)
        open(Self.course + [Self.pdfExam], in: app)
        XCTAssertTrue(element(app, "exam.pdf").waitForExistence(timeout: Timeout.content))

        assertSelfTest(in: app, equals: "off")
    }

    // MARK: - Helpers

    @MainActor
    private func launch(shieldOff: Bool) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ViFiMockData", "-ViFiCaptureShieldSelfTest"] + (shieldOff ? ["-ViFiCaptureShieldOff"] : [])
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

    /// Every self-test marker on screen settles on `expected` (none may stay `pending` or report another outcome).
    @MainActor
    private func assertSelfTest(in app: XCUIApplication, equals expected: String) {
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
        XCTAssertTrue(values.allSatisfy { $0 == expected }, "Self-test outcomes \(values), expected all \(expected)")
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}

import XCTest

/// The recording / mirroring cover: `-ViFiSimulateCapture` forces the scene capture trait on. In the default
/// `fallback` cover mode the cover appears only while the shield is not protecting the page (owner decision K4), so
/// the "appears" case switches the shield off with `-ViFiCaptureShieldOff`.
nonisolated final class CaptureCoverUITests: XCTestCase {
    private enum Timeout {
        static let content: TimeInterval = 15
    }

    private static let path = [
        "BOZOK ÜNİVERSİTESİ", "MÜHENDİSLİK MİMARLIK FAKÜLTESİ", "BİLGİSAYAR MÜHENDİSLİĞİ",
        "MÜHENDİSLİK MATEMATİĞİ", "2018 VİZE",
    ]

    @MainActor
    func testCoverAppearsOverTheExamWhileCapturedWithoutTheShield() {
        let app = launchApp(simulatingCapture: true, shieldOff: true)
        openPDFExam(in: app)

        XCTAssertTrue(element(in: app, "exam.captureCover").waitForExistence(timeout: Timeout.content))
    }

    @MainActor
    func testShieldedPageStaysVisibleWhileCaptured() {
        let app = launchApp(simulatingCapture: true)
        openPDFExam(in: app)

        XCTAssertTrue(element(in: app, "exam.pdf").waitForExistence(timeout: Timeout.content))
        XCTAssertFalse(element(in: app, "exam.captureCover").exists)
    }

    @MainActor
    func testCoverIsAbsentWithoutCapture() {
        let app = launchApp(simulatingCapture: false)
        openPDFExam(in: app)

        XCTAssertTrue(element(in: app, "exam.pdf").waitForExistence(timeout: Timeout.content))
        XCTAssertFalse(element(in: app, "exam.captureCover").exists)
    }

    // MARK: - Helpers

    @MainActor
    private func launchApp(simulatingCapture: Bool, shieldOff: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ViFiMockData"]
            + (simulatingCapture ? ["-ViFiSimulateCapture"] : [])
            + (shieldOff ? ["-ViFiCaptureShieldOff"] : [])
        app.launch()
        XCTAssertTrue(element(in: app, "home.list").waitForExistence(timeout: Timeout.content), "The home list did not appear")
        return app
    }

    @MainActor
    private func openPDFExam(in app: XCUIApplication) {
        for name in Self.path {
            let row = element(in: app, "row.\(name)")
            XCTAssertTrue(row.waitForExistence(timeout: Timeout.content), "Row \(name) did not appear")
            row.tap()
        }
    }

    @MainActor
    private func element(in app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}

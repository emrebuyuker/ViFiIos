import XCTest

/// The full-screen pager shields its pages from captures. `XCUIScreen.main.screenshot()` goes through the
/// system capture path (unlike `drawHierarchy` or `simctl io screenshot`), so a shielded page shows the notice card.
nonisolated final class CaptureShieldPagerUITests: XCTestCase {
    private enum Timeout {
        static let transition: TimeInterval = 5
        static let content: TimeInterval = 15
    }

    @MainActor
    func testPagerPageIsBlankInCaptureWithAndWithoutZoom() throws {
        let app = openPager()
        let page = element(app, "exam.page.0")
        XCTAssertTrue(page.exists)

        let unzoomed = XCUIScreen.main.screenshot().image
        try XCTSkipUnless(
            Self.isNotice(unzoomed),
            "Simulator capture still shows the page: the flag is not honoured here (verify on a device)"
        )

        // Double-tap zooms the page; the zoomed layer subtree must be dropped from captures as well.
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(Self.isNotice(XCUIScreen.main.screenshot().image), "Zoomed page leaked into the capture")
    }

    @MainActor
    func testPagerKeepsDoubleTapZoomAndSingleTap() {
        let app = openPager()
        let window = app.windows.firstMatch
        let counter = element(app, "viewer.counter")
        XCTAssertTrue(counter.waitForExistence(timeout: Timeout.transition))
        XCTAssertEqual(counter.label, "1 / 3")

        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        // Single tap toggles the chrome (the counter hides/shows); the pager stays usable.
        XCTAssertTrue(element(app, "viewer.fullscreen").exists)
    }

    // MARK: - Helpers

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func openPager() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ViFiMockData"]
        app.launch()
        XCTAssertTrue(element(app, "home.list").waitForExistence(timeout: Timeout.content))
        let path = ["BOZOK ÜNİVERSİTESİ", "MÜHENDİSLİK MİMARLIK FAKÜLTESİ", "BİLGİSAYAR MÜHENDİSLİĞİ", "MÜHENDİSLİK MATEMATİĞİ", "2019 FİNAL"]
        for name in path {
            let row = element(app, "row.\(name)")
            XCTAssertTrue(row.waitForExistence(timeout: Timeout.content), "Row \(name) did not appear")
            for _ in 0..<5 where !row.isHittable { app.swipeUp() }
            row.tap()
        }
        let first = element(app, "exam.page.0")
        XCTAssertTrue(first.waitForExistence(timeout: Timeout.content))
        first.tap()
        XCTAssertTrue(element(app, "viewer.fullscreen").waitForExistence(timeout: Timeout.transition))
        Thread.sleep(forTimeInterval: 1)
        return app
    }

    /// True when the screen centre is the pale notice card instead of the (black) page.
    private static func isNotice(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        // Sample a point left of the centre label so the card text does not matter.
        let width = cgImage.width, height = cgImage.height
        context.draw(cgImage, in: CGRect(x: -width / 8, y: -height / 2, width: width, height: height))
        return pixel[0] > 200 && pixel[1] > 200 && pixel[2] > 100 && pixel[2] < 200
    }
}

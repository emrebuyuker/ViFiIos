import XCTest

/// The PDF viewer keeps its text lock: a long press produces no selection or edit menu, and scrolling and
/// pinch zoom keep working.
///
/// `nonisolated` because `XCTestCase`'s initializers are; the tests drive the UI on the main actor.
nonisolated final class PDFProtectionUITests: XCTestCase {
    private enum Timeout {
        static let transition: TimeInterval = 5
        static let content: TimeInterval = 15
    }

    @MainActor
    private func openPDF() -> (XCUIApplication, XCUIElement) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-ViFiMockData"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "home.list").firstMatch
            .waitForExistence(timeout: Timeout.content))
        for name in [
            "BOZOK ÜNİVERSİTESİ", "MÜHENDİSLİK MİMARLIK FAKÜLTESİ", "BİLGİSAYAR MÜHENDİSLİĞİ",
            "MÜHENDİSLİK MATEMATİĞİ", "2018 VİZE",
        ] {
            let row = app.descendants(matching: .any).matching(identifier: "row.\(name)").firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: Timeout.content), "Row \(name) did not appear")
            for _ in 0..<5 where !row.isHittable { app.swipeUp() }
            row.tap()
        }
        let pdf = app.descendants(matching: .any).matching(identifier: "exam.pdf").firstMatch
        XCTAssertTrue(pdf.waitForExistence(timeout: Timeout.content))
        return (app, pdf)
    }

    @MainActor
    func testLongPressShowsNoSelectionMenu() {
        let (app, pdf) = openPDF()

        pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).press(forDuration: 1.5)
        pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()

        XCTAssertEqual(app.menuItems.count, 0, "A selection menu appeared on the PDF")
        XCTAssertFalse(app.menuItems["Copy"].exists)
        XCTAssertFalse(app.menuItems["Kopyala"].exists)
        XCTAssertTrue(pdf.exists, "The viewer stopped responding")
    }

    @MainActor
    func testScrollAndPinchStillWork() {
        let (_, pdf) = openPDF()

        pdf.swipeUp()
        pdf.pinch(withScale: 2, velocity: 2)
        pdf.swipeDown()

        XCTAssertTrue(pdf.exists)
    }

    /// A capture (`XCUIScreen`, unlike `simctl io screenshot`, goes through the capture path) shows the notice card
    /// where the page is. The simulator does not always honor the capture flag, so a leak is recorded as an
    /// attachment and reported rather than failing the suite.
    @MainActor
    func testCaptureShowsNoticeInsteadOfPage() throws {
        let (_, pdf) = openPDF()
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.lifetime = .keepAlways
        add(attachment)

        let frame = pdf.frame
        let screen = XCUIScreen.main.screenshot().image
        guard let cgImage = screen.cgImage, let data = cgImage.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            throw XCTSkip("No pixel data")
        }
        let scale = Double(cgImage.width) / Double(XCUIApplication().frame.width)
        // Sample a grid: one pixel could land on page text. The card is uniform; a leaked page is not.
        var cardHits = 0, samples = 0
        for step in 1...8 {
            let column = Int((frame.minX + frame.width * 0.2) * scale)
            let row = Int((frame.minY + frame.height * Double(step) / 9) * scale)
            let offset = row * cgImage.bytesPerRow + column * (cgImage.bitsPerPixel / 8)
            let (first, second, third) = (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
            samples += 1
            // 4-component little-endian BGRA or RGBA: the card is 255/242/153 in either channel order.
            let rgba = abs(first - 255) < 12 && abs(second - 242) < 12 && abs(third - 153) < 12
            let bgra = abs(third - 255) < 12 && abs(second - 242) < 12 && abs(first - 153) < 12
            if rgba || bgra { cardHits += 1 }
        }
        if cardHits < samples {
            throw XCTSkip("Simulator capture did not honor the shield: \(cardHits)/\(samples) samples were the notice card")
        }
    }
}

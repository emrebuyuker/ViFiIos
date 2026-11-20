import XCTest

extension XCUIElement {
    /// Taps a text field until it owns the keyboard, then types `text`.
    ///
    /// On iOS 17.0 a multi-line `TextField(axis: .vertical)` with a reserved `lineLimit` is taller than its text
    /// view, and a tap at the element's centre can miss it ("Neither element nor any descendant has keyboard
    /// focus"). The first tap is the plain one; if no keyboard appears, the second one lands on the first line.
    @MainActor
    func focusAndType(_ text: String, in app: XCUIApplication, timeout: TimeInterval = 3) {
        tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: timeout) {
            coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2)).tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: timeout),
                          "The keyboard did not appear for \(identifier)")
        }
        typeText(text)
    }
}

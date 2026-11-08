import ObjectiveC
import Testing
import UIKit
@testable import ViFi

/// Structural checks for the capture shield. Simulator tests cannot prove that a capture is blank (only a device
/// or `XCUIScreen` can); they catch an OS build where the donor canvas or the KVC preconditions disappear.
@MainActor
@Suite("CaptureShield")
struct CaptureShieldTests {
    /// Read-only, test-only probe of the mask UIKit writes. The app binary never names this key.
    private func captureMask(of view: UIView) -> Int? {
        (view.layer.value(forKey: "disableUpdateMask") as? NSNumber)?.intValue
    }

    @Test("The shield is available on every supported simulator runtime")
    func isAvailable() {
        #expect(CaptureShield.shared.isAvailable)
    }

    @Test("KVC on `layer` reaches UIView's `_layer` ivar")
    func kvcPreconditions() {
        #expect(class_getInstanceVariable(UIView.self, "_layer") != nil)
        #expect(UIView.accessInstanceVariablesDirectly)
    }

    @Test("UIView has no `_setLayer:` selector, so KVC cannot route through a private setter")
    func noPrivateSetLayerSelector() {
        #expect(!UIView.instancesRespond(to: NSSelectorFromString("_setLayer:")))
    }

    @Test("Protecting flags the view's own layer; unprotecting clears it")
    func setProtectedTogglesTheFlag() {
        let view = UIView()
        #expect(captureMask(of: view) == 0)

        #expect(CaptureShield.shared.setProtected(true, on: view))
        #expect(captureMask(of: view) == 0x12)

        #expect(CaptureShield.shared.setProtected(false, on: view))
        #expect(captureMask(of: view) == 0)
    }

    @Test("The swap keeps the view's layer and its delegate", arguments: [true, false])
    func delegateIsPreserved(isProtected: Bool) {
        let view = UIView()
        let layer = view.layer

        #expect(CaptureShield.shared.setProtected(isProtected, on: view))

        #expect(view.layer === layer)
        #expect(view.layer.delegate === view)
    }

    @Test("Protecting one view does not flag another view")
    func swapIsScopedToTheTarget() {
        let target = UIView()
        let bystander = UIView()

        CaptureShield.shared.setProtected(true, on: target)

        #expect(captureMask(of: target) == 0x12)
        #expect(captureMask(of: bystander) == 0)
    }

    @Test("The container flags its content, puts the unflagged notice behind it and carries `exam.shield`")
    func shieldedViewLayout() throws {
        let imageView = UIImageView()
        let container = CaptureShieldedView(content: imageView)

        #expect(container.isShielded)
        #expect(container.content === imageView)
        #expect(container.accessibilityIdentifier == "exam.shield")
        #expect(container.subviews.count == 2)

        let notice = try #require(container.subviews.first as? CaptureNoticeView)
        #expect(container.subviews.last === imageView)
        #expect(notice.accessibilityElementsHidden)
        #expect(notice.label.text == "Sınav içeriği korumalıdır")

        #expect(captureMask(of: imageView) == 0x12)
        #expect(captureMask(of: notice) == 0)
        #expect(captureMask(of: container) == 0)
        #expect(imageView.layer.delegate === imageView)
    }
}

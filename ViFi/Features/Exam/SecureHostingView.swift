import os
import SwiftUI
import UIKit

/// Hosts a single view inside a secure `UITextField`'s render canvas, which iOS excludes from screenshots and
/// screen recordings — the same undocumented technique media and banking apps use to keep paid content out of
/// captures.
///
/// It is best-effort by design: the secure canvas is an undocumented internal view, so if it cannot be found
/// on some future iOS the hosted view is shown **unprotected** (and the loss is logged) rather than left blank
/// for the real user — a visible-but-unprotected exam is always better than a blank one. The hosted view keeps
/// its own layout, gestures and accessibility; touches are routed straight to it so zoom and scrolling work
/// even though the secure field itself is non-interactive scaffolding.
final class SecureHostingView: UIView {
    /// The protected view. Rendered inside the secure canvas when protection is available.
    let hostedView: UIView

    /// Whether the hosted view is currently inside the secure canvas (i.e. excluded from captures).
    private(set) var isProtected = false

    private let secureField = UITextField()
    private var didEmbedHostedView = false

    init(protecting hostedView: UIView) {
        self.hostedView = hostedView
        super.init(frame: .zero)
        secureField.isSecureTextEntry = true
        // The field is only scaffolding for its secure canvas: no keyboard, no caret, no editing.
        secureField.isUserInteractionEnabled = false
        pin(secureField, to: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        embedHostedViewIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The secure canvas is built lazily once the field is laid out in a window; embed as soon as it exists.
        embedHostedViewIfNeeded()
    }

    /// Routes every touch to the hosted view, so its gestures fire regardless of the secure field's own
    /// (non-interactive) hit-testing.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard didEmbedHostedView, bounds.contains(point) else {
            return super.hitTest(point, with: event)
        }
        let localPoint = hostedView.convert(point, from: self)
        return hostedView.hitTest(localPoint, with: event) ?? super.hitTest(point, with: event)
    }

    private func embedHostedViewIfNeeded() {
        guard !didEmbedHostedView, window != nil else { return }
        secureField.layoutIfNeeded()

        if let canvas = secureField.subviews.first {
            didEmbedHostedView = true
            isProtected = true
            // The canvas must pass touches down even though the field above it is non-interactive.
            canvas.isUserInteractionEnabled = true
            // Add into the canvas (for the secure render path) but size to our full bounds, bypassing the
            // text field's content insets so the exam fills the view edge to edge.
            canvas.addSubview(hostedView)
            pinEdges(hostedView, to: self)
        } else {
            didEmbedHostedView = true
            isProtected = false
            Logger.app.error("Secure screenshot layer unavailable; exam content is shown unprotected")
            pin(hostedView, to: self)
        }
    }

    private func pin(_ child: UIView, to parent: UIView) {
        parent.addSubview(child)
        pinEdges(child, to: parent)
    }

    private func pinEdges(_ child: UIView, to anchorView: UIView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: anchorView.topAnchor),
            child.bottomAnchor.constraint(equalTo: anchorView.bottomAnchor),
            child.leadingAnchor.constraint(equalTo: anchorView.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: anchorView.trailingAnchor),
        ])
    }
}

/// A `UIImage` shown inside the secure host, so a list page is excluded from captures. It fills its frame
/// aspect-fit, like `Image(uiImage:).resizable().scaledToFit()`; apply `.aspectRatio` at the call site to
/// drive its height.
struct SecureImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> SecureHostingView {
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        // The surrounding card button carries the page's accessibility; the image itself is decorative.
        imageView.isAccessibilityElement = false
        return SecureHostingView(protecting: imageView)
    }

    func updateUIView(_ uiView: SecureHostingView, context: Context) {
        (uiView.hostedView as? UIImageView)?.image = image
    }
}

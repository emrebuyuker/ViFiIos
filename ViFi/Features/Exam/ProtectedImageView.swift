import SwiftUI
import UIKit

/// A `UIImage` shown inside a `CaptureShieldedView`, so the page is excluded from screenshots and recordings
/// (a capture shows the "Sınav içeriği korumalıdır" notice instead).
///
/// It fills its frame aspect-fit, like `Image(uiImage:).resizable().scaledToFit()`; apply `.aspectRatio` at the
/// call site to drive its height. The content is opaque white, as `CaptureShieldedView` requires. A card that
/// fades this view in or out needs `.compositingGroup()` around it, and it must never sit under `.drawingGroup()`.
struct ProtectedImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> CaptureShieldedView<UIImageView> {
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.backgroundColor = .white
        imageView.isOpaque = true
        // The surrounding card button carries the page's accessibility; the image itself is decorative.
        imageView.isAccessibilityElement = false
        return CaptureShieldedView(content: imageView)
    }

    func updateUIView(_ uiView: CaptureShieldedView<UIImageView>, context: Context) {
        // Mutate in place; replacing the content view would leave the new one unflagged.
        uiView.content.image = image
    }
}

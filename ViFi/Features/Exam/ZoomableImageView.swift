import SwiftUI
import UIKit

/// An image that fits its bounds and can be zoomed: pinch between 1× and `maximumZoomScale`,
/// double-tap to zoom in on the tapped point or back out. The image stays centred at any scale.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    var maximumZoomScale: CGFloat = 5
    /// When `false` the zoom is reset; pagers pass `false` for pages that are not on screen.
    var isActive = true
    /// VoiceOver label of the image.
    var imageDescription: String?
    /// A single tap that is not part of a double tap, e.g. to toggle surrounding controls.
    var onSingleTap: (() -> Void)?

    func makeUIView(context: Context) -> ZoomableImageScrollView {
        ZoomableImageScrollView()
    }

    func updateUIView(_ scrollView: ZoomableImageScrollView, context: Context) {
        scrollView.maximumZoomScale = max(maximumZoomScale, scrollView.minimumZoomScale)
        scrollView.onSingleTap = onSingleTap
        scrollView.imageDescription = imageDescription
        scrollView.display(image)
        if !isActive {
            scrollView.resetZoom(animated: false)
        }
    }
}

/// The `UIScrollView` behind `ZoomableImageView`.
///
/// At zoom 1 the image view is sized to fit the bounds; zooming scales it with a transform and
/// `centerImage()` keeps it in the middle while it is smaller than the bounds.
final class ZoomableImageScrollView: UIScrollView, UIScrollViewDelegate {
    var onSingleTap: (() -> Void)?

    var imageDescription: String? {
        get { imageView.accessibilityLabel }
        set { imageView.accessibilityLabel = newValue }
    }

    private let imageView = UIImageView()
    /// The bounds size the image was last fitted to; a new size (rotation, split view) refits it.
    private var fittedBoundsSize: CGSize = .zero

    private static let doubleTapZoomScale: CGFloat = 2.5

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shows `image`. A sharper version of the same picture (same aspect ratio) keeps the current zoom.
    func display(_ image: UIImage) {
        guard image !== imageView.image else { return }
        let isSamePicture = imageView.image.map { Self.hasSameAspectRatio($0, image) } ?? false
        imageView.image = image
        if !isSamePicture {
            fitImage()
        }
    }

    func resetZoom(animated: Bool) {
        guard zoomScale != minimumZoomScale else { return }
        setZoomScale(minimumZoomScale, animated: animated)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != fittedBoundsSize {
            fitImage()
        }
        centerImage()
    }

    // MARK: - UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImage()
    }

    // MARK: - Private

    private func configure() {
        delegate = self
        backgroundColor = .clear
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        decelerationRate = .fast
        bouncesZoom = true
        minimumZoomScale = 1
        maximumZoomScale = 5

        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityTraits = .image
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)
    }

    /// Resets the zoom and sizes the image to fit the bounds (aspect fit).
    private func fitImage() {
        guard let image = imageView.image,
              bounds.width > 0, bounds.height > 0,
              image.size.width > 0, image.size.height > 0 else { return }

        fittedBoundsSize = bounds.size
        zoomScale = minimumZoomScale

        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let fittedSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        imageView.frame = CGRect(origin: .zero, size: fittedSize)
        contentSize = fittedSize
        centerImage()
    }

    /// Centres the image while it is smaller than the bounds; pins it to the content origin once larger.
    private func centerImage() {
        imageView.center = CGPoint(
            x: max(contentSize.width, bounds.width) / 2,
            y: max(contentSize.height, bounds.height) / 2
        )
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard imageView.image != nil else { return }
        guard zoomScale <= minimumZoomScale + 0.01 else {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }

        // Zoom at least enough to fill the screen (a portrait page in landscape fills the width).
        let fillScale = max(bounds.width / imageView.bounds.width, bounds.height / imageView.bounds.height)
        let targetScale = min(maximumZoomScale, max(Self.doubleTapZoomScale, fillScale))

        let location = recognizer.location(in: imageView)
        let point = CGPoint(
            x: min(max(location.x, 0), imageView.bounds.width),
            y: min(max(location.y, 0), imageView.bounds.height)
        )
        let size = CGSize(width: bounds.width / targetScale, height: bounds.height / targetScale)
        let rect = CGRect(
            x: point.x - size.width / 2,
            y: point.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        zoom(to: rect, animated: true)
    }

    @objc private func handleSingleTap() {
        onSingleTap?()
    }

    private static func hasSameAspectRatio(_ lhs: UIImage, _ rhs: UIImage) -> Bool {
        guard lhs.size.height > 0, rhs.size.height > 0 else { return false }
        return abs(lhs.size.width / lhs.size.height - rhs.size.width / rhs.size.height) < 0.01
    }
}

#if DEBUG
#Preview {
    Group {
        if let url = ExamPreviewFixtures.imagesDocument.fileURLs.first,
           let image = UIImage(contentsOfFile: url.path(percentEncoded: false)) {
            ZoomableImageView(image: image, imageDescription: "Sayfa 1")
        } else {
            ContentUnavailableView("Örnek sayfa bulunamadı", systemImage: "photo")
        }
    }
    .background(.black)
    .ignoresSafeArea()
    .environment(AppEnvironment.mock())
}
#endif

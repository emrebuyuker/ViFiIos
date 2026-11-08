import UIKit

/// Hosts one exam surface so that a capture shows a notice where the page was, while the screen shows the page.
///
/// Layout (back to front): an unflagged, opaque `CaptureNoticeView` ("Sınav içeriği korumalıdır"), then `content`,
/// whose own layer `CaptureShield` flags. Captures drop the flagged layer and its whole subtree (zoom transforms,
/// PDFKit tiles, image sublayers), so the notice behind it is what a screenshot or recording shows.
///
/// Usage (one container per UIKit surface that draws exam pixels, created in `makeUIView`):
/// - Pager: `CaptureShieldedView(content: ZoomableImageScrollView())`
/// - PDF: `CaptureShieldedView(content: PDFView())`
/// - List thumbnail: `CaptureShieldedView(content: UIImageView())` — the container is required there: a bare
///   `UIImageView` is sized by SwiftUI to the image's intrinsic size and breaks the card layout.
/// `updateUIView` mutates `content` in place; never replace it, or the new view would be unflagged.
///
/// Contract for callers:
/// - `content` must be **opaque** (pager black, list white card, PDF `systemGroupedBackground`), otherwise the notice
///   shows through on screen. A fading card around it needs `.compositingGroup()` for the same reason.
/// - Gestures, layout and accessibility stay on `content`; the container adds no hit-test routing.
/// - Never put the container under `.drawingGroup()`, `shouldRasterize`, `render(in:)`, snapshot transitions or
///   `ImageRenderer`: they bypass or flatten the flagged layer.
/// - Fails open: when the shield is unavailable or switched off (`CaptureShield.isSwitchedOn`) `isShielded` is `false`, the page is still shown (and a fault is
///   logged by `CaptureShield`); the recording cover remains the fallback.
final class CaptureShieldedView<Content: UIView>: UIView {
    /// The exam surface. Its own layer carries the capture exclusion.
    let content: Content

    /// Whether `content`'s layer was flagged successfully. `false` means captures show the page.
    private(set) var isShielded = false

    private let notice = CaptureNoticeView()

    #if DEBUG
    /// `-ViFiCaptureShieldSelfTest` only: measures whether captures leave `content` out (`exam.shield.selfTest`).
    private var selfTest: CaptureShieldSelfTestProbe?
    #endif

    init(content: Content) {
        self.content = content
        super.init(frame: .zero)
        accessibilityIdentifier = "exam.shield"
        pin(notice)
        pin(content)
        isShielded = CaptureShield.isSwitchedOn && CaptureShield.shared.setProtected(true, on: content)
        #if DEBUG
        if CaptureShieldSelfTest.isEnabled {
            selfTest = CaptureShieldSelfTestProbe(container: self)
        }
        #endif
    }

    #if DEBUG
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            selfTest?.start(content: content, isShielded: isShielded)
        }
    }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // Explicit deinit: Swift 6.3.3 with MainActor default isolation crashes at -O on the implicit deinit of a
    // generic UIView subclass when targeting iOS < 18.4 (SCREEN-PROTECTION-OPUS.md). Do not remove.
    deinit {}

    private func pin(_ child: UIView) {
        child.translatesAutoresizingMaskIntoConstraints = false
        addSubview(child)
        NSLayoutConstraint.activate([
            child.topAnchor.constraint(equalTo: topAnchor),
            child.bottomAnchor.constraint(equalTo: bottomAnchor),
            child.leadingAnchor.constraint(equalTo: leadingAnchor),
            child.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }
}

/// Unflagged, opaque notice that sits behind shielded content; it is what a capture shows.
///
/// Hidden from VoiceOver: on screen it is always covered by the page, which keeps its own accessibility.
final class CaptureNoticeView: UIView {
    /// Pale yellow, opaque; black text on it keeps contrast well above 4.5:1.
    static let cardColor = UIColor(red: 1.0, green: 0.95, blue: 0.6, alpha: 1)

    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Self.cardColor
        isOpaque = true
        accessibilityElementsHidden = true
        isUserInteractionEnabled = false

        label.text = String(localized: "Sınav içeriği korumalıdır")
        label.font = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: .systemFont(ofSize: 15, weight: .semibold), maximumPointSize: 28)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .black
        label.textAlignment = .center
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }
}

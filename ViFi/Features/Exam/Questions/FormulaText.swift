import SwiftMath
import UIKit

/// Builds the UIKit views of Markdown + LaTeX question text (4.2.0): paragraphs as labels (inline formulas flow with
/// the words as text attachments) and display formulas as their own horizontally scrollable `MTMathUILabel`.
///
/// Everything here draws exam content, so the views it returns must live inside a `CaptureShieldedView`
/// (`QuestionContentView` is that content). Malformed LaTeX never crashes: the formula's source is shown as text.
enum FormulaText {
    /// The text style of a block of question text.
    struct Style {
        var font: UIFont
        var color: UIColor
        /// SwiftMath's point size, kept in step with `font` so formulas scale with Dynamic Type.
        var mathFontSize: CGFloat { font.pointSize }

        /// Body text that follows Dynamic Type up to a cap (the card would otherwise grow past the screen).
        static func body(traits: UITraitCollection) -> Style {
            let metrics = UIFontMetrics(forTextStyle: .body)
            let font = metrics.scaledFont(
                for: .systemFont(ofSize: 17), maximumPointSize: 34, compatibleWith: traits
            )
            return Style(font: font, color: UIColor.label.resolvedColor(with: traits))
        }

        func with(font: UIFont) -> Style {
            Style(font: font, color: color)
        }
    }

    /// The views for `text`: paragraphs (text with inline formulas) and display formulas, in order.
    static func views(for text: String, style: Style) -> [UIView] {
        var views: [UIView] = []
        var paragraph = NSMutableAttributedString()

        func flushParagraph() {
            let trimmed = trimmedTrailingNewlines(paragraph)
            if trimmed.length > 0 { views.append(label(for: trimmed)) }
            paragraph = NSMutableAttributedString()
        }

        for run in MathTextTokenizer.tokenize(text) {
            switch run {
            case let .text(string):
                paragraph.append(markdown(string, style: style))
            case let .inlineMath(latex):
                paragraph.append(inlineMath(latex, style: style))
            case let .displayMath(latex):
                flushParagraph()
                views.append(displayMath(latex, style: style))
            }
        }
        flushParagraph()
        return views
    }

    // MARK: - Text

    /// Inline Markdown (bold, italic, code) as an attributed string; unparsable Markdown stays plain text.
    static func markdown(_ string: String, style: Style) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: style.font, .foregroundColor: style.color]
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard let parsed = try? AttributedString(markdown: string, options: options) else {
            return NSAttributedString(string: string, attributes: base)
        }
        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let piece = String(parsed[run.range].characters)
            let intent = run.inlinePresentationIntent ?? []
            var attributes = base
            attributes[.font] = font(for: intent, base: style.font)
            if intent.contains(.strikethrough) {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: piece, attributes: attributes))
        }
        return result
    }

    private static func font(for intent: InlinePresentationIntent, base: UIFont) -> UIFont {
        if intent.contains(.code) {
            return .monospacedSystemFont(ofSize: base.pointSize * 0.92, weight: .regular)
        }
        var traits = UIFontDescriptor.SymbolicTraits()
        if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
        if intent.contains(.emphasized) { traits.insert(.traitItalic) }
        guard !traits.isEmpty, let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else { return base }
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    private static func trimmedTrailingNewlines(_ text: NSMutableAttributedString) -> NSAttributedString {
        var end = text.length
        while end > 0, text.attributedSubstring(from: NSRange(location: end - 1, length: 1)).string.first?.isNewline == true {
            end -= 1
        }
        // Leading blank lines after a display formula are layout, not content.
        var start = 0
        while start < end, text.attributedSubstring(from: NSRange(location: start, length: 1)).string.first?.isNewline == true {
            start += 1
        }
        return text.attributedSubstring(from: NSRange(location: start, length: end - start))
    }

    static func label(for text: NSAttributedString) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.attributedText = text
        label.isAccessibilityElement = false
        return label
    }

    // MARK: - Formulas

    /// A formula as a text attachment sitting on the baseline; the formula's source when it cannot be typeset.
    private static func inlineMath(_ latex: String, style: Style) -> NSAttributedString {
        let fallback = NSAttributedString(
            string: "$\(latex)$", attributes: [.font: style.font, .foregroundColor: style.color]
        )
        let probe = MTMathUILabel()
        probe.labelMode = .text
        probe.fontSize = style.mathFontSize
        probe.latex = latex
        guard probe.error == nil else { return fallback }
        probe.frame = CGRect(origin: .zero, size: probe.intrinsicContentSize)
        probe.layoutIfNeeded()
        guard let descent = probe.displayList?.descent else { return fallback }

        let renderer = MTMathImage(
            latex: latex, fontSize: style.mathFontSize, textColor: style.color, labelMode: .text, textAlignment: .left
        )
        let (error, image) = renderer.asImage()
        guard error == nil, let image else { return fallback }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(x: 0, y: -descent, width: image.size.width, height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }

    private static func displayMath(_ latex: String, style: Style) -> UIView {
        let label = MTMathUILabel()
        label.labelMode = .display
        label.fontSize = style.mathFontSize * 1.1
        label.textColor = style.color
        label.latex = latex
        guard label.error == nil else {
            return Self.label(for: NSAttributedString(
                string: "$$\(latex)$$", attributes: [.font: style.font, .foregroundColor: style.color]
            ))
        }
        return DisplayMathView(label: label)
    }
}

/// A display formula, centered when it fits and scrolling sideways when it is wider than the card.
final class DisplayMathView: UIScrollView {
    private let formula: MTMathUILabel

    init(label: MTMathUILabel) {
        formula = label
        super.init(frame: .zero)
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        alwaysBounceHorizontal = false
        isAccessibilityElement = false
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {}

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: ceil(formula.intrinsicContentSize.height))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = formula.intrinsicContentSize
        formula.frame = CGRect(x: max(0, (bounds.width - size.width) / 2), y: 0, width: size.width, height: size.height)
        contentSize = CGSize(width: max(size.width, bounds.width), height: size.height)
    }
}

import SwiftMath
import UIKit

/// Builds the UIKit views of Markdown + LaTeX question text (4.2.0): paragraphs as labels (inline formulas flow with
/// the words as text attachments) and display formulas as their own horizontally scrollable `MTMathUILabel`.
///
/// Everything here draws exam content, so the views it returns must live inside a `CaptureShieldedView`
/// (`QuestionContentView` is that content). Commands SwiftMath lacks are rewritten first (`LatexCompatibility`);
/// malformed LaTeX never crashes: the formula's source is shown as text.
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

    /// The views for `text`: paragraphs (text with inline formulas) and display formulas, in order. A formula wider
    /// than `lineWidth` wraps onto the next line like words (`MathLineBreaker` pieces); nothing scrolls sideways.
    static func views(for text: String, style: Style, lineWidth: CGFloat = .greatestFiniteMagnitude) -> [UIView] {
        var views: [UIView] = []
        var paragraph = NSMutableAttributedString()

        func flushParagraph() {
            let trimmed = trimmedTrailingNewlines(paragraph)
            // Spaces left between two display formulas are not a paragraph (an inline formula is an attachment
            // character, so a paragraph holding one is never blank).
            let isBlank = trimmed.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !isBlank { views.append(label(for: trimmed)) }
            paragraph = NSMutableAttributedString()
        }

        for run in MathTextTokenizer.tokenize(text) {
            switch run {
            case let .text(string):
                paragraph.append(markdown(string, style: style))
            case let .inlineMath(latex):
                paragraph.append(inlineMath(latex, style: style, lineWidth: lineWidth))
            case let .displayMath(latex):
                flushParagraph()
                views.append(displayMath(latex, style: style, lineWidth: lineWidth))
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

    /// A typeset formula as a text attachment sitting on the baseline.
    private struct Typeset {
        let image: UIImage
        let descent: CGFloat
        var width: CGFloat { image.size.width }

        /// The attachment, shrunk to `maxWidth` when wider (the last resort for a piece that cannot break).
        func attachment(maxWidth: CGFloat) -> NSAttributedString {
            let scale = width > maxWidth && maxWidth > 0 ? maxWidth / width : 1
            let attachment = NSTextAttachment()
            attachment.image = image
            attachment.bounds = CGRect(
                x: 0, y: -descent * scale, width: image.size.width * scale, height: image.size.height * scale
            )
            return NSAttributedString(attachment: attachment)
        }
    }

    private static func typeset(_ latex: String, mode: MTMathUILabelMode, fontSize: CGFloat, color: UIColor) -> Typeset? {
        let probe = MTMathUILabel()
        probe.labelMode = mode
        probe.fontSize = fontSize
        probe.latex = latex
        guard probe.error == nil else { return nil }
        probe.frame = CGRect(origin: .zero, size: probe.intrinsicContentSize)
        probe.layoutIfNeeded()
        guard let descent = probe.displayList?.descent else { return nil }
        let renderer = MTMathImage(latex: latex, fontSize: fontSize, textColor: color, labelMode: mode, textAlignment: .left)
        let (error, image) = renderer.asImage()
        guard error == nil, let image else { return nil }
        return Typeset(image: image, descent: descent)
    }

    /// `latex` as attachments that fit `lineWidth`: whole when it fits, otherwise its `MathLineBreaker` pieces joined by
    /// a text space at `fontSize` (the line-break opportunity, and the comma's / operator's spacing the piece images lose
    /// at their edges), a piece that still does not fit shrunk to the line. `nil` when it cannot be typeset.
    private static func wrappingMath(
        _ latex: String, mode: MTMathUILabelMode, fontSize: CGFloat, style: Style, lineWidth: CGFloat
    ) -> NSAttributedString? {
        let color = style.color
        let spaceFont = style.font.withSize(fontSize)
        guard let whole = typeset(latex, mode: mode, fontSize: fontSize, color: color) else { return nil }
        guard whole.width > lineWidth else { return whole.attachment(maxWidth: lineWidth) }
        let pieces = MathLineBreaker.pieces(latex)
        let typesetPieces = pieces.compactMap { typeset($0, mode: mode, fontSize: fontSize, color: color) }
        guard pieces.count > 1, typesetPieces.count == pieces.count else { return whole.attachment(maxWidth: lineWidth) }
        let result = NSMutableAttributedString()
        for (index, piece) in typesetPieces.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: " ", attributes: [.font: spaceFont])) }
            result.append(piece.attachment(maxWidth: lineWidth))
        }
        return result
    }

    /// An inline formula flowing with the words; the formula's source when it cannot be typeset.
    private static func inlineMath(_ source: String, style: Style, lineWidth: CGFloat) -> NSAttributedString {
        let latex = LatexCompatibility.normalize(source)
        return wrappingMath(latex, mode: .text, fontSize: style.mathFontSize, style: style, lineWidth: lineWidth)
            ?? NSAttributedString(string: "$\(latex)$", attributes: [.font: style.font, .foregroundColor: style.color])
    }

    /// A display formula on its own line, centered; one wider than the line wraps (centered lines of pieces).
    private static func displayMath(_ source: String, style: Style, lineWidth: CGFloat) -> UIView {
        let latex = LatexCompatibility.normalize(source)
        let fontSize = style.mathFontSize * 1.1
        let label = MTMathUILabel()
        label.labelMode = .display
        label.fontSize = fontSize
        label.textColor = style.color
        label.latex = latex
        guard label.error == nil else {
            return Self.label(for: NSAttributedString(
                string: "$$\(latex)$$", attributes: [.font: style.font, .foregroundColor: style.color]
            ))
        }
        guard label.intrinsicContentSize.width > lineWidth,
              let wrapped = wrappingMath(latex, mode: .display, fontSize: fontSize, style: style, lineWidth: lineWidth)
        else { return DisplayMathView(label: label) }
        let centered = NSMutableAttributedString(attributedString: wrapped)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        centered.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: centered.length))
        return Self.label(for: centered)
    }
}

/// A display formula that fits its line, centered (a wider one is wrapped by `FormulaText.displayMath` instead).
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

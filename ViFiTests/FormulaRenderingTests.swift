import SwiftMath
import Testing
import UIKit
@testable import ViFi

/// Faz 0.5 compatibility probe for SwiftMath (4.2.0 formula rendering): the formulas the sample questions use parse
/// and lay out, and the label can sit inside the capture shield like every exam surface (`CaptureShieldedView`).
@MainActor
@Suite("Formula rendering (SwiftMath)")
struct FormulaRenderingTests {
    /// The LaTeX between `$…$` / `$$…$$` delimiters of a Markdown + LaTeX string.
    private func formulas(in text: String) -> [String] {
        text.replacingOccurrences(of: "$$", with: "$")
            .components(separatedBy: "$")
            .enumerated()
            .filter { $0.offset.isMultiple(of: 2) == false }
            .map(\.element)
            .filter { !$0.isEmpty }
    }

    @Test("Every formula in the sample questions parses and has a size")
    func sampleFormulasRender() {
        let questions = MockExamQuestionReader.sampleQuestions(examId: "probe")
        let texts = questions.flatMap { [$0.text, $0.answer.text] + $0.solution + $0.choices.map(\.text) }
        let latex = texts.flatMap(formulas(in:))
        #expect(latex.count >= 10)
        for formula in latex {
            let label = MTMathUILabel()
            label.fontSize = 17
            label.latex = formula
            #expect(label.error == nil, "\(formula)")
            #expect(label.intrinsicContentSize.width > 0, "\(formula)")
        }
    }

    @Test("Every LaTeX compatibility case typesets once normalized")
    func normalizedFormulasRender() {
        // `\varnothingx` is the case that must stay untouched (not a table command), so it cannot render.
        let latex = LatexCompatibilityTests.cases
            .filter { !$0.input.contains("varnothingx") }
            .map { LatexCompatibility.normalize($0.input) }
            .flatMap(formulas(in:))
        #expect(latex.count >= 10)
        for formula in latex {
            let label = MTMathUILabel()
            label.fontSize = 17
            label.latex = formula
            #expect(label.error == nil, "\(formula)")
        }
    }

    @Test("Each command in the table is one SwiftMath cannot typeset, so the table stays minimal")
    func tableCommandsAreUnsupported() {
        for entry in LatexCompatibility.replacements {
            let label = MTMathUILabel()
            label.latex = "\\\(entry.command)(x)"
            #expect(label.error != nil, "SwiftMath now supports \\\(entry.command); drop it from the table")
        }
    }

    @Test("A formula wider than the line wraps in its paragraph as pieces; nothing scrolls sideways")
    func wideFormulaWraps() {
        let formula = #"$B = \{\emptyset, X \times Y, \{(a,k), (a,m)\}, \{(b,k), (b,m), (c,k), (c,m)\}\}$"#
        let style = FormulaText.Style(font: .systemFont(ofSize: 17), color: .label)
        func attachments(in views: [UIView]) -> [NSTextAttachment] {
            views.compactMap { ($0 as? UILabel)?.attributedText }.flatMap { text in
                var found: [NSTextAttachment] = []
                text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                    if let attachment = value as? NSTextAttachment { found.append(attachment) }
                }
                return found
            }
        }

        let unlimited = FormulaText.views(for: "Taban \(formula) bulunur.", style: style)
        #expect(unlimited.count == 1)
        #expect(attachments(in: unlimited).count == 1)

        let narrow = FormulaText.views(for: "Taban \(formula) bulunur.", style: style, lineWidth: 200)
        #expect(narrow.count == 1, "one paragraph, wrapping")
        #expect(!narrow.contains { $0 is UIScrollView })
        let pieces = attachments(in: narrow)
        #expect(pieces.count == MathLineBreaker.pieces(String(formula.dropFirst().dropLast())).count)
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { $0.bounds.width <= 200 })

        let display = FormulaText.views(for: "$" + formula + "$", style: style, lineWidth: 200)
        #expect(display.count == 1)
        #expect(display.first is UILabel, "a wide display formula wraps as centered lines")
        let fitting = FormulaText.views(for: "$$x = 1$$", style: style, lineWidth: 200)
        #expect(fitting.first is DisplayMathView)

        let short = FormulaText.views(for: "Sonuç $x = 1$ olur.", style: style, lineWidth: 200)
        #expect(attachments(in: short).count == 1)
    }

    @Test("Every piece of the sample formulas typesets on its own")
    func piecesTypeset() {
        let samples = [
            #"B = \{\emptyset, X \times Y, \{(a,k), (a,m)\}, \{(b,k), (b,m), (c,k), (c,m)\}\}"#,
            #"\Im_1 \times \Im_2 = \{\emptyset, \{(a,k)\}, \{(b,k), (c,k)\}\}"#,
            #"f(x) = x^3 - 2x^2 + \frac{1}{x} - \sqrt{x+1} \leq 10"#,
            #"\int_0^{\pi/2} \frac{dx}{2 + \cos x} = \frac{\pi}{3\sqrt{3}}"#
        ]
        for sample in samples {
            for piece in MathLineBreaker.pieces(sample) {
                let label = MTMathUILabel()
                label.latex = piece
                #expect(label.error == nil, "\(piece)")
            }
        }
    }

    @Test("Malformed LaTeX reports an error instead of crashing")
    func malformedFormula() {
        let label = MTMathUILabel()
        label.latex = "\\frac{1}{"
        #expect(label.error != nil)
    }

    @Test("A formula label can be the content of the capture shield")
    func formulaInsideShield() {
        let label = MTMathUILabel()
        label.latex = "\\int_0^1 x^2 \\, dx"
        let container = CaptureShieldedView(content: label)
        container.frame = CGRect(x: 0, y: 0, width: 320, height: 80)
        container.layoutIfNeeded()

        #expect(container.isShielded)
        #expect(container.content === label)
        #expect(label.frame.width > 0)
    }
}

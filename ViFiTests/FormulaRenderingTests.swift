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

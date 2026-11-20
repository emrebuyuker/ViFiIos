import Foundation

/// Splits a formula into pieces that can be typeset one by one, so a formula wider than its line wraps onto the next
/// line like words (4.2.0). SwiftMath typesets a formula as one unbreakable box; `FormulaText` draws each piece as its
/// own attachment with a line-break opportunity between them.
///
/// Breaks only at the formula's top level: never inside `{…}` groups such as `\frac{…}{…}` or `\text{…}`, inside
/// `\left…\right`, inside `\begin…\end` environments, or inside `(…)` / `[…]` (a pair `(a,k)` or an interval stays
/// whole). Set braces `\{…\}` do not protect their content, so a long set can wrap between its elements:
/// - after a comma;
/// - around a relation (`=`, `<`, `>`, `\leq`, `\in`, `\subset`, `\Rightarrow` …) or a binary operator (`+`, `-`,
///   `\times`, `\cup` …), which becomes a piece of its own. A `+` / `-` only counts after an operand, so a sign
///   (`= -1`, `x^{-1}`, `(-a`) never moves away from its number.
///
/// Pieces are trimmed: a typeset image loses the space at its edges anyway, so the drawing side joins pieces with a
/// text space (the line-break opportunity), standing for the comma's or operator's own spacing.
///
/// Pure and UIKit-free. Joining the pieces gives the input back, apart from whitespace at the break points. Mirrored by
/// the Android contract (STRUCTURED-EXAMS.md §5.3).
nonisolated enum MathLineBreaker {
    static let relations: Set<String> = [
        "leq", "geq", "neq", "ne", "le", "ge", "in", "notin", "ni", "subset", "subseteq", "supset", "supseteq",
        "approx", "equiv", "sim", "simeq", "cong", "propto", "to", "mapsto", "rightarrow", "Rightarrow",
        "Longrightarrow", "leftarrow", "Leftarrow", "Longleftarrow", "leftrightarrow", "Leftrightarrow",
        "Longleftrightarrow", "iff"
    ]
    static let binaryOperators: Set<String> = [
        "times", "cdot", "cup", "cap", "pm", "mp", "setminus", "div", "oplus", "otimes", "wedge", "vee", "circ"
    ]

    private enum Token: Equatable {
        case command(String)   // `\name`
        case symbol(String)    // `\` + one non-letter, e.g. `\{`, `\,`, `\\`
        case char(Character)

        var source: String {
            switch self {
            case let .command(name): "\\" + name
            case let .symbol(text): text
            case let .char(character): String(character)
            }
        }

        var isSpace: Bool {
            if case let .char(character) = self { return character.isWhitespace }
            return false
        }
    }

    /// The pieces of `latex`; a single piece when it has no top-level break point.
    static func pieces(_ latex: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        var depth = 0
        var parentheses = 0
        var previous: Token?
        var breakAfterComma = false

        func flush() {
            let piece = current.trimmingCharacters(in: .whitespaces)
            if !piece.isEmpty { pieces.append(piece) }
            current = ""
        }

        for token in tokenize(latex) {
            let atTopLevel = depth == 0 && parentheses == 0
            if breakAfterComma, !token.isSpace {
                breakAfterComma = false
                if atTopLevel { flush() }
            }
            if atTopLevel, isOperatorBreak(token, after: previous) {
                // The operator stands alone; the text spaces around it carry its spacing.
                flush()
                pieces.append(token.source)
                previous = token
                continue
            }
            current += token.source
            depth = max(0, depth + depthChange(of: token))
            if depth == 0 { parentheses = max(0, parentheses + parenthesisChange(of: token)) }
            if depth == 0, parentheses == 0, token == .char(",") { breakAfterComma = true }
            if !token.isSpace { previous = token }
        }
        flush()
        return pieces.isEmpty ? [latex] : pieces
    }

    private static func isOperatorBreak(_ token: Token, after previous: Token?) -> Bool {
        switch token {
        case let .char(character) where "=<>".contains(character):
            return true
        case let .char(character) where "+-".contains(character):
            return isOperand(previous)
        case let .command(name) where relations.contains(name) || binaryOperators.contains(name):
            return true
        default:
            return false
        }
    }

    /// Whether `token` can end an operand, so a following `+` / `-` is a binary operator, not a sign.
    private static func isOperand(_ token: Token?) -> Bool {
        switch token {
        case let .char(character):
            return character.isLetter || character.isNumber || ")]}|!'".contains(character)
        case let .symbol(text):
            return text == "\\}" || text == "\\|"
        case let .command(name):
            return !relations.contains(name) && !binaryOperators.contains(name)
                && !["left", "right", "begin", "end"].contains(name)
        case nil:
            return false
        }
    }

    private static func depthChange(of token: Token) -> Int {
        switch token {
        case .char("{"), .command("left"), .command("begin"): 1
        case .char("}"), .command("right"), .command("end"): -1
        default: 0
        }
    }

    private static func parenthesisChange(of token: Token) -> Int {
        switch token {
        case .char("("), .char("["): 1
        case .char(")"), .char("]"): -1
        default: 0
        }
    }

    private static func tokenize(_ latex: String) -> [Token] {
        var tokens: [Token] = []
        var index = latex.startIndex
        while index < latex.endIndex {
            let character = latex[index]
            guard character == "\\" else {
                tokens.append(.char(character))
                index = latex.index(after: index)
                continue
            }
            let next = latex.index(after: index)
            guard next < latex.endIndex else {
                tokens.append(.char(character))
                index = next
                continue
            }
            if latex[next].isASCII, latex[next].isLetter {
                var end = next
                while end < latex.endIndex, latex[end].isASCII, latex[end].isLetter { end = latex.index(after: end) }
                tokens.append(.command(String(latex[next..<end])))
                index = end
            } else {
                tokens.append(.symbol(String(latex[index...next])))
                index = latex.index(after: next)
            }
        }
        return tokens
    }
}

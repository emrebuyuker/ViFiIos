import Foundation

/// One run of a question's Markdown + LaTeX text.
nonisolated enum MathRun: Equatable, Sendable {
    /// Markdown text (rendered by the text layer).
    case text(String)
    /// LaTeX between `$…$`, shown inline with the surrounding text.
    case inlineMath(String)
    /// LaTeX between `$$…$$`, shown on its own line.
    case displayMath(String)
}

/// Splits a question's text into text, inline-math and display-math runs.
///
/// Pure and UIKit-free, so it is unit-tested. The rules follow Pandoc's `$` convention, so prices and stray dollar
/// signs stay text: an opening `$` must be followed by a non-space, a closing `$` must follow a non-space and must
/// not be followed by a digit ("$5 ve $6" is text, "$x$." is math). `\$` is a literal dollar sign, a `$` with no
/// closing partner in its paragraph stays text, and an empty `$$ $$` is dropped. It never throws: whatever cannot be
/// read as math comes back as text.
nonisolated enum MathTextTokenizer {
    static func tokenize(_ input: String) -> [MathRun] {
        let chars = Array(input)
        var runs: [MathRun] = []
        var buffer = ""
        var index = 0

        func flush() {
            defer { buffer = "" }
            guard !buffer.isEmpty else { return }
            // Text around a dropped (empty) formula joins into one run.
            if case let .text(previous)? = runs.last {
                runs[runs.count - 1] = .text(previous + buffer)
            } else {
                runs.append(.text(buffer))
            }
        }

        while index < chars.count {
            let char = chars[index]
            if char == "\\", index + 1 < chars.count, chars[index + 1] == "$" {
                buffer.append("$")
                index += 2
            } else if char == "$", index + 1 < chars.count, chars[index + 1] == "$" {
                if let close = closingDisplay(in: chars, from: index + 2) {
                    let latex = String(chars[(index + 2)..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
                    flush()
                    if !latex.isEmpty { runs.append(.displayMath(latex)) }
                    index = close + 2
                } else {
                    buffer.append("$$")
                    index += 2
                }
            } else if char == "$" {
                if let close = closingInline(in: chars, openAt: index) {
                    flush()
                    runs.append(.inlineMath(String(chars[(index + 1)..<close])))
                    index = close + 1
                } else {
                    buffer.append("$")
                    index += 1
                }
            } else {
                buffer.append(char)
                index += 1
            }
        }
        flush()
        return runs
    }

    /// The text without math delimiters (LaTeX source kept as is): a spoken fallback when no `speech` is stored.
    static func plainText(_ input: String) -> String {
        tokenize(input).map { run -> String in
            switch run {
            case let .text(text), let .inlineMath(text), let .displayMath(text): text
            }
        }.joined()
    }

    // MARK: - Delimiter search

    /// The index of the `$$` closing a display formula that starts at `start`, or `nil`.
    private static func closingDisplay(in chars: [Character], from start: Int) -> Int? {
        var index = start
        while index + 1 < chars.count {
            if chars[index] == "\\" {
                index += 2
                continue
            }
            if chars[index] == "$", chars[index + 1] == "$" { return index }
            index += 1
        }
        return nil
    }

    /// The index of the `$` closing an inline formula opened at `open`, or `nil` (Pandoc rules, same paragraph).
    private static func closingInline(in chars: [Character], openAt open: Int) -> Int? {
        let first = open + 1
        guard first < chars.count, !chars[first].isWhitespace, chars[first] != "$" else { return nil }
        var index = first
        while index < chars.count {
            let char = chars[index]
            if char == "\\" {
                index += 2
                continue
            }
            if char == "\n", index + 1 < chars.count, chars[index + 1] == "\n" { return nil }
            if char == "$" {
                let followedByDigit = index + 1 < chars.count && chars[index + 1].isASCII && chars[index + 1].isNumber
                if !chars[index - 1].isWhitespace, !followedByDigit { return index }
                return nil
            }
            index += 1
        }
        return nil
    }
}

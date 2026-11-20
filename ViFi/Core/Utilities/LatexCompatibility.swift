import Foundation

/// Rewrites standard LaTeX commands SwiftMath 1.7.3 cannot typeset into renderer-safe equivalents (4.2.0).
///
/// Mirrors `LATEX_REPLACEMENTS` / `normalizeLatex` in `firebase/functions/conversions/schema.js` (same pairs, same
/// order) and the Android contract (STRUCTURED-EXAMS.md). The server normalizes everything it writes; the app applies
/// the same table to every formula before drawing it, so questions written before the table existed render too.
/// Only exact command names match (`\big` never touches `\bigcup`), and a command after an escaped backslash
/// (`\\dots` = line break + "dots") is left alone. Pure and idempotent.
nonisolated enum LatexCompatibility {
    /// Command name (without the backslash) → its replacement; an empty replacement drops a sizing / numbering command.
    static let replacements: [(command: String, replacement: String)] = [
        ("varnothing", "\\emptyset"),
        ("dfrac", "\\frac"),
        ("tfrac", "\\frac"),
        ("dbinom", "\\binom"),
        ("tbinom", "\\binom"),
        ("leqslant", "\\leq"),
        ("geqslant", "\\geq"),
        ("implies", "\\Longrightarrow"),
        ("impliedby", "\\Longleftarrow"),
        ("dots", "\\ldots"),
        ("lvert", "|"),
        ("rvert", "|"),
        ("lVert", "\\Vert"),
        ("rVert", "\\Vert"),
        ("operatorname", "\\mathrm"),
        ("coloneqq", ":="),
        ("bigl", ""),
        ("bigr", ""),
        ("Bigl", ""),
        ("Bigr", ""),
        ("biggl", ""),
        ("biggr", ""),
        ("Biggl", ""),
        ("Biggr", ""),
        ("big", ""),
        ("Big", ""),
        ("bigg", ""),
        ("Bigg", ""),
        ("nonumber", "")
    ]

    private static let map: [String: String] = Dictionary(
        replacements.map { ($0.command, $0.replacement) }, uniquingKeysWith: { first, _ in first }
    )

    /// `latex` with every listed command replaced; unchanged when it holds none of them.
    static func normalize(_ latex: String) -> String {
        guard latex.contains("\\") else { return latex }
        // An escaped backslash (`\\`, kept as is so `\\dots` stays a line break + "dots") or a whole command name
        // `\name`; the same pattern as the server's. Local because `Regex` is not `Sendable`.
        let pattern = /\\\\|\\([A-Za-z]+)/
        return latex.replacing(pattern) { match in
            guard let name = match.output.1 else { return String(match.output.0) }
            return map[String(name)] ?? String(match.output.0)
        }
    }
}

import Testing
@testable import ViFi

/// `LatexCompatibility` (4.2.0). The cases are the same as `LATEX_CASES` in firebase/tests/conversionSchema.test.mjs,
/// so the app and the server rewrite formulas identically.
@Suite("LaTeX compatibility")
struct LatexCompatibilityTests {
    nonisolated static let cases: [(input: String, expected: String)] = [
        (#"$\Im_1 = \{\varnothing, X\}$"#, #"$\Im_1 = \{\emptyset, X\}$"#),
        (#"$x_n := \dfrac{(-1)^n}{n}$ ve $\tfrac{1}{2}$"#, #"$x_n := \frac{(-1)^n}{n}$ ve $\frac{1}{2}$"#),
        (#"$\dbinom{n}{k}$"#, #"$\binom{n}{k}$"#),
        (#"$a \leqslant b \geqslant c$"#, #"$a \leq b \geq c$"#),
        (#"$p \implies q$"#, #"$p \Longrightarrow q$"#),
        (#"$1, 2, \dots, n$"#, #"$1, 2, \ldots, n$"#),
        (#"$\lvert x \rvert + \lVert v \rVert$"#, #"$| x | + \Vert v \Vert$"#),
        (#"$\operatorname{rank} A$"#, #"$\mathrm{rank} A$"#),
        (#"$\bigl( a \bigr) \Big[ b \Big]$"#, #"$( a ) [ b ]$"#),
        (#"$\bigcup_i A_i \cap \bigcap_j B_j$"#, #"$\bigcup_i A_i \cap \bigcap_j B_j$"#),
        (#"$\varnothingx$"#, #"$\varnothingx$"#),
        (#"satır\\dots"#, #"satır\\dots"#),
        ("Formülsüz metin.", "Formülsüz metin.")
    ]

    @Test("Each shared case normalizes like the server", arguments: Self.cases.indices)
    func sharedCase(index: Int) {
        let (input, expected) = Self.cases[index]
        #expect(LatexCompatibility.normalize(input) == expected)
    }

    @Test("Normalizing is idempotent")
    func idempotent() {
        for (input, _) in Self.cases {
            let once = LatexCompatibility.normalize(input)
            #expect(LatexCompatibility.normalize(once) == once)
        }
    }

    @Test("Every replacement target is left alone")
    func replacementsAreStable() {
        for entry in LatexCompatibility.replacements {
            #expect(LatexCompatibility.normalize(entry.replacement) == entry.replacement)
        }
    }

    @Test("The table has no duplicate commands")
    func uniqueCommands() {
        let commands = LatexCompatibility.replacements.map(\.command)
        #expect(Set(commands).count == commands.count)
    }
}

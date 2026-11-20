import Testing
@testable import ViFi

/// `MathLineBreaker` (4.2.0): where a too-wide formula may wrap.
@Suite("Math line breaker")
struct MathLineBreakerTests {
    private func withoutSpaces(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }

    @Test("A set wraps between its elements; pairs in parentheses stay whole")
    func setElements() {
        let pieces = MathLineBreaker.pieces(#"B = \{\emptyset, \{(a,k), (a,m)\}\}"#)
        #expect(pieces == ["B", "=", #"\{\emptyset,"#, #"\{(a,k),"#, #"(a,m)\}\}"#])
    }

    @Test("Relations and binary operators become pieces of their own")
    func operators() {
        #expect(MathLineBreaker.pieces("a + b = c") == ["a", "+", "b", "=", "c"])
        #expect(MathLineBreaker.pieces(#"X \times Y \subset Z"#) == ["X", #"\times"#, "Y", #"\subset"#, "Z"])
    }

    @Test("A sign never leaves its number")
    func signs() {
        #expect(MathLineBreaker.pieces("x = -1") == ["x", "=", "-1"])
        #expect(MathLineBreaker.pieces("x^-1") == ["x^-1"])
        #expect(MathLineBreaker.pieces("(-a + b)") == ["(-a + b)"])
        #expect(MathLineBreaker.pieces("-a + b") == ["-a", "+", "b"])
    }

    @Test("Groups, \\left…\\right, environments and \\text are never split", arguments: [
        #"\frac{a + b, c}{d = e}"#,
        #"\left( a, b = c \right)"#,
        #"\begin{cases} a, & x = 1 \\ b, & x = 2 \end{cases}"#,
        #"\text{a, b = c}"#,
        "[a, b]",
        "f(x, y)"
    ])
    func unbreakable(latex: String) {
        #expect(MathLineBreaker.pieces(latex) == [latex])
    }

    @Test("A trailing comma or a formula without break points is one piece")
    func singlePieces() {
        #expect(MathLineBreaker.pieces("a,") == ["a,"])
        #expect(MathLineBreaker.pieces(#"\sqrt{x}"#) == [#"\sqrt{x}"#])
        #expect(MathLineBreaker.pieces("") == [""])
    }

    @Test("Joining the pieces gives the input back apart from spaces", arguments: [
        #"B = \{\emptyset, X \times Y, \{(a,k), (a,m)\}, \{(b,k), (b,m), (c,k), (c,m)\}\}"#,
        #"f(x) = x^3 - 2x^2 + \frac{1}{x} - \sqrt{x+1} \leq 10"#,
        #"\Im_1 \times \Im_2 = \{\emptyset, \{(a,k)\}\}"#,
        #"a \\ b, c"#
    ])
    func roundTrip(latex: String) {
        #expect(withoutSpaces(MathLineBreaker.pieces(latex).joined()) == withoutSpaces(latex))
    }
}

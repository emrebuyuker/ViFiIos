import Testing
@testable import ViFi

@Suite("MathTextTokenizer")
struct MathTextTokenizerTests {
    @Test("Plain text is one text run, and empty input has no runs")
    func plainText() {
        #expect(MathTextTokenizer.tokenize("Bir soru") == [.text("Bir soru")])
        #expect(MathTextTokenizer.tokenize("").isEmpty)
    }

    @Test("Inline math splits the text around it")
    func inlineMath() {
        #expect(MathTextTokenizer.tokenize("$x^2$ ifadesi") == [.inlineMath("x^2"), .text(" ifadesi")])
        #expect(MathTextTokenizer.tokenize("a $b$ c") == [.text("a "), .inlineMath("b"), .text(" c")])
    }

    @Test("Display math keeps its own run and is trimmed")
    func displayMath() {
        #expect(
            MathTextTokenizer.tokenize("Hesapla:\n$$ \\int_0^1 x\\,dx $$\nsonucu bul")
                == [.text("Hesapla:\n"), .displayMath("\\int_0^1 x\\,dx"), .text("\nsonucu bul")]
        )
    }

    @Test("Several formulas in a row keep their order")
    func mixed() {
        #expect(
            MathTextTokenizer.tokenize("$a$ ve $b$, $$c$$")
                == [.inlineMath("a"), .text(" ve "), .inlineMath("b"), .text(", "), .displayMath("c")]
        )
    }

    @Test("An escaped dollar sign is literal text")
    func escapedDollar() {
        #expect(MathTextTokenizer.tokenize("Fiyat \\$5 ve $x$") == [.text("Fiyat $5 ve "), .inlineMath("x")])
        #expect(MathTextTokenizer.tokenize("$a \\$ b$") == [.inlineMath("a \\$ b")])
    }

    @Test("Prices and stray dollar signs stay text (Pandoc rules)")
    func currencyStaysText() {
        #expect(MathTextTokenizer.tokenize("$5 ve $6 tutar") == [.text("$5 ve $6 tutar")])
        #expect(MathTextTokenizer.tokenize("Maliyet $ 10 $ olur") == [.text("Maliyet $ 10 $ olur")])
    }

    @Test("An unclosed dollar is text, not a crash")
    func unclosed() {
        #expect(MathTextTokenizer.tokenize("a $b c") == [.text("a $b c")])
        #expect(MathTextTokenizer.tokenize("a $$b c") == [.text("a $$b c")])
    }

    @Test("Inline math does not run across a blank line")
    func paragraphBoundary() {
        #expect(MathTextTokenizer.tokenize("$a\n\nb$") == [.text("$a\n\nb$")])
    }

    @Test("An empty display formula is dropped")
    func emptyDisplay() {
        #expect(MathTextTokenizer.tokenize("önce $$  $$ sonra") == [.text("önce  sonra")])
    }

    @Test("The plain text drops the delimiters and keeps the formula source")
    func plainTextFallback() {
        #expect(MathTextTokenizer.plainText("$x$ ve $$y$$ ile \\$") == "x ve y ile $")
    }

    @Test("Malformed LaTeX is still a math run; rendering falls back to its source")
    func malformedLatexIsPassedThrough() {
        #expect(MathTextTokenizer.tokenize("$\\frac{1}{$") == [.inlineMath("\\frac{1}{")])
    }
}

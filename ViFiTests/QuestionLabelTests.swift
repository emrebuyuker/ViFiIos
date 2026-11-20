import Testing
@testable import ViFi

/// `QuestionLabel` (4.2.0). Same cases as `LABEL_CASES` in firebase/tests/conversionSchema.test.mjs.
@Suite("Question label")
struct QuestionLabelTests {
    nonisolated static let cases: [(input: String, expected: String)] = [
        ("Soru 1)", "1"), ("1", "1"), ("1.", "1"), ("1)", "1"), ("(3)", "3"), ("S1", "1"), ("S.1", "1"), ("soru 5", "5"),
        ("SORU 12:", "12"), ("Soru No: 4", "4"), ("Soru 2a)", "2a"), ("2a)", "2a"), ("2 a", "2a"), ("2-b", "2b"),
        ("2.c", "2c"), ("3A", "3A"), ("  7  ", "7"), ("Ek Soru", "Ek Soru"), ("Bonus", "Bonus")
    ]

    @Test("Each shared case normalizes like the server", arguments: Self.cases.indices)
    func sharedCase(index: Int) {
        let (input, expected) = Self.cases[index]
        #expect(QuestionLabel.normalize(input) == expected)
    }

    @Test("Normalizing is idempotent")
    func idempotent() {
        for (input, _) in Self.cases {
            let once = QuestionLabel.normalize(input)
            #expect(QuestionLabel.normalize(once) == once)
        }
    }

    @Test("The parser reads a published \"Soru 1)\" label as \"1\"")
    func parserNormalizes() {
        let question = ExamQuestionParser.question(
            id: "e-001", data: ["order": 1, "label": "Soru 1)", "text": "Soru metni", "answer": ["text": "Cevap"]], examId: "e"
        )
        #expect(question?.label == "1")
    }
}

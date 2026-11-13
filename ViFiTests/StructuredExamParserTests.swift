import Foundation
import Testing
@testable import ViFi

@Suite("ExamQuestionParser")
struct ExamQuestionParserTests {
    private func doc(_ id: String, _ overrides: [String: Any] = [:]) -> (id: String, data: [String: Any]) {
        var data: [String: Any] = [
            "schemaVersion": 1, "examId": "e1", "order": 1, "label": "1",
            "text": "  $x^2$ nedir?  ", "speech": "x kare nedir?",
            "answer": ["text": "$4$", "choice": "B"],
            "choices": [["label": "A", "text": "2"], ["label": "B", "text": "4"], ["label": "", "text": "boş"]],
            "figures": [["storagePath": "questionFigures/exam-e1/001-1.jpg", "width": 800, "height": 0], ["width": 1]],
            "solution": ["adım", "", 3], "topics": ["cebir"], "difficulty": 7,
        ]
        data.merge(overrides) { _, new in new }
        return (id, data)
    }

    @Test("A published question parses with trimming, defaults and invalid entries dropped")
    func parsesPublished() throws {
        let question = try #require(ExamQuestionParser.questions(from: [doc("e1-001")], examId: "fallback").first)
        #expect(question.id == "e1-001")
        #expect(question.examId == "e1")
        #expect(question.text == "$x^2$ nedir?")
        #expect(question.choices.map(\.label) == ["A", "B"])
        #expect(question.figures == [QuestionFigure(storagePath: "questionFigures/exam-e1/001-1.jpg", width: 800, height: nil)])
        #expect(question.answer == QuestionAnswer(text: "$4$", choice: "B", speech: nil))
        #expect(question.solution == ["adım"])
        #expect(question.difficulty == 3)
        #expect(question.confidence == nil)
        #expect(!question.needsReview)
    }

    @Test("Questions are ordered by order; drafts take the exam id from the caller and keep review fields")
    func ordersAndDrafts() {
        let docs = [
            doc("002", ["order": 2, "examId": NSNull(), "confidence": 0.4, "needsReview": true]),
            doc("001", ["order": 1, "examId": NSNull()]),
        ]
        let questions = ExamQuestionParser.questions(from: docs, examId: "sub-x")
        #expect(questions.map(\.id) == ["001", "002"])
        #expect(questions.allSatisfy { $0.examId == "sub-x" })
        #expect(questions.last?.confidence == 0.4)
        #expect(questions.last?.needsReview == true)
    }

    @Test("Unusable documents are skipped: no text, no answer, bad order, newer schema")
    func skipsUnusable() {
        let docs = [
            doc("a", ["text": "   "]),
            doc("b", ["answer": ["choice": "A"]]),
            doc("c", ["order": 0]),
            doc("d", ["schemaVersion": 2]),
            doc("e", ["order": 5]),
        ]
        #expect(ExamQuestionParser.questions(from: docs, examId: "e1").map(\.id) == ["e"])
    }

    @Test("Missing label and speech fall back to the order and the text")
    func fallbacks() throws {
        let data = doc("x", ["label": NSNull(), "speech": NSNull(), "order": 4]).data
        let question = try #require(ExamQuestionParser.question(id: "x", data: data, examId: "e1"))
        #expect(question.label == "4")
        #expect(question.speech == question.text)
    }

    @Test("The bundled sample questions parse (mock data)") @MainActor
    func sampleFixtureParses() {
        let questions = MockExamQuestionReader.sampleQuestions(examId: "demo")
        #expect(questions.count == 3)
        #expect(questions.map(\.id) == ["demo-001", "demo-002", "demo-003"])
        #expect(questions[1].answer.choice == "A")
        #expect(questions[2].figures.count == 1)
    }
}

@Suite("ExamConversionParser")
struct ExamConversionParserTests {
    @Test("A job document parses its source, status, provider, usage and placement")
    func parsesJob() throws {
        let data: [String: Any] = [
            "source": ["type": "submission", "submissionId": "s1"], "kind": "PDF", "status": "ready",
            "model": ["provider": "gemini", "id": "gemini-pro"], "attempts": 2, "error": "",
            "usage": ["inputTokens": 1_000, "outputTokens": 200, "costUsd": 0.31],
            "placement": ["names": ["Bozok", "Müh", "Bilg", "Mat", "2019 FİNAL"], "ids": ["a"]],
            "createdAt": Date(timeIntervalSince1970: 10),
        ]
        let job = try #require(ExamConversionParser.conversion(id: "sub-s1", data: data))
        #expect(job.source == .submission(submissionId: "s1"))
        #expect(job.source.jobId == "sub-s1")
        #expect(job.kind == .pdf)
        #expect(job.status == .ready)
        #expect(job.provider == .gemini)
        #expect(job.attempts == 2)
        #expect(job.error == nil)
        #expect(job.usage == ConversionUsage(inputTokens: 1_000, outputTokens: 200, costUsd: 0.31))
        #expect(job.placementNames.last == "2019 FİNAL")
        #expect(job.createdAt == Date(timeIntervalSince1970: 10))
    }

    @Test("A legacy job builds the exam- job id; unknown providers stay nil")
    func legacyJob() throws {
        let data: [String: Any] = ["source": ["type": "legacy", "examId": "e9"], "kind": "JPG", "status": "queued", "model": ["provider": "gpt"]]
        let job = try #require(ExamConversionParser.conversion(id: "exam-e9", data: data))
        #expect(job.source.jobId == "exam-e9")
        #expect(job.provider == nil)
        #expect(job.usage == nil)
        #expect(!job.status.isTerminal)
    }

    @Test("Jobs without a valid source, kind or status are skipped")
    func rejectsInvalid() {
        let base: [String: Any] = ["source": ["type": "legacy", "examId": "e"], "kind": "JPG", "status": "ready"]
        #expect(ExamConversionParser.conversion(id: "x", data: base) != nil)
        #expect(ExamConversionParser.conversion(id: "x", data: base.merging(["source": ["type": "legacy"]]) { $1 }) == nil)
        #expect(ExamConversionParser.conversion(id: "x", data: base.merging(["kind": "DOC"]) { $1 }) == nil)
        #expect(ExamConversionParser.conversion(id: "x", data: base.merging(["status": "done"]) { $1 }) == nil)
    }
}

import SwiftUI
import Testing
import UIKit
@testable import ViFi

/// The UIKit question surface: it lives inside the capture shield, grows with its content and speaks `speech`.
@MainActor
@Suite("QuestionContentView")
struct QuestionContentViewTests {
    private let loader = RemoteFileLoader()

    private func shielded(_ question: ExamQuestion, revealed: Bool, width: CGFloat = 340) -> CaptureShieldedView<QuestionContentView> {
        let container = CaptureShieldedView(content: QuestionContentView())
        container.content.configure(question: question, isAnswerRevealed: revealed, figureURLs: [], loader: loader)
        container.frame = CGRect(x: 0, y: 0, width: width, height: container.content.height(fitting: width))
        container.layoutIfNeeded()
        return container
    }

    private func question(
        text: String = "$x$ kaçtır?", speech: String = "x kaçtır?", choices: [QuestionChoice] = [],
        answer: QuestionAnswer = QuestionAnswer(text: "$1$", choice: nil, speech: "bir")
    ) -> ExamQuestion {
        ExamQuestion(
            id: "e-001", examId: "e", order: 1, label: "1", text: text, speech: speech, choices: choices, figures: [],
            answer: answer, solution: ["$x = 1$"], topics: [], difficulty: 1, confidence: nil, needsReview: false,
            updatedAt: nil
        )
    }

    @Test("The question surface is flagged by the capture shield")
    func insideShield() {
        let container = shielded(question(), revealed: false)

        #expect(container.isShielded)
        #expect(container.content.isOpaque)
    }

    @Test("Revealing the answer makes the card taller")
    func revealGrows() {
        let content = QuestionContentView()
        content.configure(question: question(), isAnswerRevealed: false, figureURLs: [], loader: loader)
        let hidden = content.height(fitting: 340)
        content.configure(question: question(), isAnswerRevealed: true, figureURLs: [], loader: loader)
        let revealed = content.height(fitting: 340)

        #expect(hidden > 0)
        #expect(revealed > hidden)
    }

    @Test("VoiceOver reads the stored speech, never the LaTeX")
    func speech() {
        let sample = question(
            text: "$\\frac{1}{2}$ kaçtır?", speech: "bir bölü iki kaçtır?",
            choices: [QuestionChoice(label: "A", text: "$x = 1$")],
            answer: QuestionAnswer(text: "$\\frac{1}{2}$", choice: "A", speech: "yarım")
        )

        let spoken = QuestionContentView.questionSpeech(sample)
        let answer = QuestionContentView.answerSpeech(sample)

        #expect(spoken.hasPrefix("bir bölü iki kaçtır?"))
        #expect(!spoken.contains("\\frac"))
        #expect(answer.contains("yarım"))
        #expect(!answer.contains("\\frac"))
        #expect(answer.contains("yapay zekâ"))
    }

    @Test("Without answer speech the answer text is read without delimiters")
    func answerSpeechFallback() {
        let sample = question(text: "Soru", speech: "", answer: QuestionAnswer(text: "$x = 3$", choice: nil, speech: nil))

        #expect(QuestionContentView.answerSpeech(sample).contains("x = 3"))
        #expect(!QuestionContentView.answerSpeech(sample).contains("$"))
        #expect(QuestionContentView.questionSpeech(sample).hasPrefix("Soru"))
    }

    @Test("Every sample formula and a malformed one lay out without crashing")
    func sampleQuestionsLayOut() {
        let samples = MockExamQuestionReader.sampleQuestions(examId: "probe")
        let broken = question(text: "Bozuk $\\frac{1}{$ ve $$\\unknowncmd{$$ metin")

        for sample in samples + [broken] {
            let container = shielded(sample, revealed: true)
            #expect(container.frame.height > 0)
        }
    }
}

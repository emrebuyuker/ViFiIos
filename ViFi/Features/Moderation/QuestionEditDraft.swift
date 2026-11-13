import Foundation

/// The editable state of one question's content while an admin edits it (a draft before publishing, or a
/// published question, K15): text, speech, choices, the answer and the solution steps.
///
/// Pure and view-free so the validation and the round trip back to an `ExamQuestion` are unit-tested. Limits mirror
/// `LIMITS` in `firebase/functions/conversions/schema.js`.
struct QuestionEditDraft: Equatable {
    enum Limit {
        static let text = 8000
        static let speech = 8000
        static let choices = 10
        static let choiceLabel = 4
        static let choiceText = 2000
        static let answerText = 4000
        static let solutionSteps = 30
        static let solutionStep = 2000
    }

    struct Choice: Identifiable, Equatable {
        let id: UUID
        var label: String
        var text: String

        init(id: UUID = UUID(), label: String = "", text: String = "") {
            self.id = id
            self.label = label
            self.text = text
        }
    }

    struct Step: Identifiable, Equatable {
        let id: UUID
        var text: String

        init(id: UUID = UUID(), text: String = "") {
            self.id = id
            self.text = text
        }
    }

    var text: String
    var speech: String
    var choices: [Choice]
    var answerText: String
    /// The correct choice label; empty for a non-multiple-choice answer.
    var answerChoice: String
    var answerSpeech: String
    var solution: [Step]

    init(question: ExamQuestion) {
        text = question.text
        speech = question.speech
        choices = question.choices.map { Choice(label: $0.label, text: $0.text) }
        answerText = question.answer.text
        answerChoice = question.answer.choice ?? ""
        answerSpeech = question.answer.speech ?? ""
        solution = question.solution.map { Step(text: $0) }
    }

    /// The first problem that stops saving (Turkish, shown under the form), or `nil` when the draft is valid.
    var validationMessage: String? {
        if trimmed(text).isEmpty { return String(localized: "Soru metni boş olamaz.") }
        if text.count > Limit.text || speech.count > Limit.speech { return String(localized: "Metin çok uzun.") }
        if trimmed(answerText).isEmpty { return String(localized: "Cevap metni boş olamaz.") }
        if answerText.count > Limit.answerText { return String(localized: "Cevap metni çok uzun.") }
        if choices.count > Limit.choices || solution.count > Limit.solutionSteps {
            return String(localized: "Çok fazla şık ya da çözüm adımı var.")
        }
        let cleanChoices = choices.filter { !trimmed($0.label).isEmpty || !trimmed($0.text).isEmpty }
        if cleanChoices.contains(where: { trimmed($0.label).isEmpty || trimmed($0.text).isEmpty }) {
            return String(localized: "Her şıkkın harfi ve metni dolu olmalı.")
        }
        if cleanChoices.contains(where: { $0.label.count > Limit.choiceLabel || $0.text.count > Limit.choiceText }) {
            return String(localized: "Bir şık çok uzun.")
        }
        if solution.contains(where: { $0.text.count > Limit.solutionStep }) { return String(localized: "Bir çözüm adımı çok uzun.") }
        let answerLabel = trimmed(answerChoice)
        if !answerLabel.isEmpty, !cleanChoices.contains(where: { trimmed($0.label) == answerLabel }) {
            return String(localized: "Doğru şık, şıklardan biri olmalı.")
        }
        return nil
    }

    var isValid: Bool { validationMessage == nil }

    /// `question` with this draft's content (blank choices and steps dropped); everything else is kept.
    func applied(to question: ExamQuestion) -> ExamQuestion {
        let answerLabel = trimmed(answerChoice)
        let speechText = trimmed(answerSpeech)
        return ExamQuestion(
            id: question.id, examId: question.examId, order: question.order, label: question.label,
            text: trimmed(text),
            speech: trimmed(speech).isEmpty ? trimmed(text) : trimmed(speech),
            choices: choices
                .map { QuestionChoice(label: trimmed($0.label), text: trimmed($0.text)) }
                .filter { !$0.label.isEmpty && !$0.text.isEmpty },
            figures: question.figures,
            answer: QuestionAnswer(
                text: trimmed(answerText),
                choice: answerLabel.isEmpty ? nil : answerLabel,
                speech: speechText.isEmpty ? nil : speechText
            ),
            solution: solution.map { trimmed($0.text) }.filter { !$0.isEmpty },
            topics: question.topics, difficulty: question.difficulty, confidence: question.confidence,
            needsReview: question.needsReview, updatedAt: question.updatedAt,
            regeneratingUntil: question.regeneratingUntil, regenerationError: question.regenerationError
        )
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

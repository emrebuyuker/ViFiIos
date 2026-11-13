import Foundation

/// Turns raw Firestore question documents (`questions/<examId>-<nnn>` or a draft under
/// `examConversions/<jobId>/questions/<nnn>`) into `ExamQuestion`s.
///
/// Pure and Firestore-free like `FirestoreArchiveParser`: callers convert `Timestamp` values to `Date` first. A
/// document that cannot be shown safely (no text, no answer, a newer `schemaVersion`) is skipped rather than shown
/// half-broken. Field names follow `firebase/functions/conversions/schema.js`.
nonisolated enum ExamQuestionParser {
    /// The newest published shape this build understands.
    static let supportedSchemaVersion = 1

    enum Field {
        static let schemaVersion = "schemaVersion"
        static let examId = "examId"
        static let order = "order"
        static let label = "label"
        static let text = "text"
        static let speech = "speech"
        static let choices = "choices"
        static let figures = "figures"
        static let answer = "answer"
        static let solution = "solution"
        static let topics = "topics"
        static let difficulty = "difficulty"
        static let confidence = "confidence"
        static let needsReview = "needsReview"
        static let updatedAt = "updatedAt"
        static let regenerationLeaseUntil = "regenerationLeaseUntil"
        static let regenerationError = "regenerationError"
        static let storagePath = "storagePath"
        static let width = "width"
        static let height = "height"
        static let choice = "choice"
    }

    /// The questions of one exam in reading order. `examId` fills drafts, which do not store it.
    static func questions(from docs: [(id: String, data: [String: Any])], examId: String) -> [ExamQuestion] {
        docs.compactMap { question(id: $0.id, data: $0.data, examId: examId) }
            .sorted { $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order }
    }

    static func question(id: String, data: [String: Any], examId fallbackExamId: String) -> ExamQuestion? {
        if let version = data[Field.schemaVersion] as? Int, version > supportedSchemaVersion { return nil }
        guard let order = data[Field.order] as? Int, order >= 1,
              let text = nonEmpty(data[Field.text]),
              let answer = answer(from: data[Field.answer]) else { return nil }
        return ExamQuestion(
            id: id,
            examId: nonEmpty(data[Field.examId]) ?? fallbackExamId,
            order: order,
            label: nonEmpty(data[Field.label]) ?? String(order),
            text: text,
            speech: nonEmpty(data[Field.speech]) ?? text,
            choices: choices(from: data[Field.choices]),
            figures: figures(from: data[Field.figures]),
            answer: answer,
            solution: strings(from: data[Field.solution]),
            topics: strings(from: data[Field.topics]),
            difficulty: min(3, max(1, data[Field.difficulty] as? Int ?? 2)),
            confidence: (data[Field.confidence] as? Double).map { min(1, max(0, $0)) },
            needsReview: data[Field.needsReview] as? Bool ?? false,
            updatedAt: data[Field.updatedAt] as? Date,
            regeneratingUntil: data[Field.regenerationLeaseUntil] as? Date,
            regenerationError: nonEmpty(data[Field.regenerationError])
        )
    }

    // MARK: - Helpers

    private static func answer(from value: Any?) -> QuestionAnswer? {
        guard let map = value as? [String: Any], let text = nonEmpty(map[Field.text]) else { return nil }
        return QuestionAnswer(text: text, choice: nonEmpty(map[Field.choice]), speech: nonEmpty(map[Field.speech]))
    }

    private static func choices(from value: Any?) -> [QuestionChoice] {
        (value as? [[String: Any]] ?? []).compactMap { entry in
            guard let label = nonEmpty(entry[Field.label]), let text = nonEmpty(entry[Field.text]) else { return nil }
            return QuestionChoice(label: label, text: text)
        }
    }

    private static func figures(from value: Any?) -> [QuestionFigure] {
        (value as? [[String: Any]] ?? []).compactMap { entry in
            guard let path = nonEmpty(entry[Field.storagePath]) else { return nil }
            return QuestionFigure(
                storagePath: path,
                width: (entry[Field.width] as? Int).flatMap { $0 > 0 ? $0 : nil },
                height: (entry[Field.height] as? Int).flatMap { $0 > 0 ? $0 : nil }
            )
        }
    }

    private static func strings(from value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap(nonEmpty)
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

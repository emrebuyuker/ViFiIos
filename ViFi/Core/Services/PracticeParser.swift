import Foundation

/// Turns the practice mode's raw documents into models: the index doc `questionPoolIndex/<subjectId>` and the
/// `nextPracticeQuestions` response. Pure and Firebase-free like `ExamQuestionParser`.
nonisolated enum PracticeParser {
    enum Field {
        static let name = "name"
        static let types = "types"
        static let questions = "questions"
        static let id = "id"
        static let examId = "examId"
        static let order = "order"
        static let examTitle = "examTitle"
        static let universityName = "universityName"
        static let poolSize = "poolSize"
        static let remainingToday = "remainingToday"
        static let limitReached = "limitReached"
    }

    /// The index document's content, or `nil` when it lists no practice-eligible type. Unknown or
    /// non-practice types, malformed maps and non-positive counts are dropped.
    static func index(from data: [String: Any], subjectId: String) -> PracticePoolIndex? {
        guard let rawTypes = data[Field.types] as? [String: Any] else { return nil }
        var types: [ExamType: [String: Int]] = [:]
        for (rawType, rawCounts) in rawTypes {
            guard let type = ExamType(rawValue: rawType), type.isPracticeEligible,
                  let counts = rawCounts as? [String: Any] else { continue }
            let valid = counts.compactMapValues { count(from: $0) }.filter { $0.value > 0 }
            if !valid.isEmpty { types[type] = valid }
        }
        guard !types.isEmpty else { return nil }
        return PracticePoolIndex(subjectId: subjectId, name: data[Field.name] as? String, types: types)
    }

    /// The callable's response. `nil` when it is not a map; a question that cannot be shown is skipped.
    static func batch(from data: Any?) -> PracticeBatch? {
        guard let map = data as? [String: Any] else { return nil }
        let questions = (map[Field.questions] as? [[String: Any]] ?? []).compactMap(question(from:))
        return PracticeBatch(
            questions: questions,
            poolSize: count(from: map[Field.poolSize] as Any) ?? 0,
            remainingToday: count(from: map[Field.remainingToday] as Any).map { max(0, $0) },
            limitReached: map[Field.limitReached] as? Bool ?? false
        )
    }

    /// One question of the response: the published shape plus `examTitle` / `universityName`.
    static func question(from data: [String: Any]) -> PracticeQuestion? {
        let examId = (data[Field.examId] as? String) ?? ""
        let order = count(from: data[Field.order] as Any) ?? 0
        let fallbackId = examId.isEmpty || order < 1 ? nil : "\(examId)-\(String(format: "%03d", order))"
        // The callable sends `updatedAt` as epoch milliseconds (JSON has no timestamp); the parser wants a `Date`.
        var fields = data
        if let millis = data[ExamQuestionParser.Field.updatedAt] as? Double {
            fields[ExamQuestionParser.Field.updatedAt] = Date(timeIntervalSince1970: millis / 1000)
        } else if data[ExamQuestionParser.Field.updatedAt] is NSNull || data[ExamQuestionParser.Field.updatedAt] is Int {
            let millis = (data[ExamQuestionParser.Field.updatedAt] as? Int).map(Double.init)
            fields[ExamQuestionParser.Field.updatedAt] = millis.map { Date(timeIntervalSince1970: $0 / 1000) }
        }
        guard let id = (data[Field.id] as? String).flatMap({ $0.isEmpty ? nil : $0 }) ?? fallbackId,
              let question = ExamQuestionParser.question(id: id, data: fields, examId: examId) else { return nil }
        return PracticeQuestion(
            question: question,
            examTitle: nonEmpty(data[Field.examTitle]),
            universityName: nonEmpty(data[Field.universityName])
        )
    }

    /// A whole number from JSON (`Int`, `NSNumber`, or an integral `Double`); `nil` for anything else, `null` included.
    private static func count(from value: Any) -> Int? {
        if value is NSNull { return nil }
        if let int = value as? Int { return int }
        if let double = value as? Double, double.rounded() == double { return Int(double) }
        return nil
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else {
            return nil
        }
        return string
    }
}

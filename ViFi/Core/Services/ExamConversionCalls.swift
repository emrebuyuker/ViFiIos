import Foundation

/// The pure, Firebase-free half of `FirebaseExamConversionService`: callable names, request payloads, response
/// parsing and the draft-edit field map. Mirrors `CALLABLES` in `firebase/functions/conversions/schema.js`.
nonisolated enum ExamConversionCalls {
    enum Name {
        static let requestConversion = "requestExamConversion"
        static let requestBulk = "requestBulkConversion"
        static let regenerate = "regenerateExamConversion"
        static let regenerateDraftQuestion = "regenerateDraftQuestion"
        static let publish = "publishExamConversion"
        static let discard = "discardExamConversion"
        static let updatePublishedQuestion = "updatePublishedQuestion"
        static let regeneratePublishedQuestion = "regeneratePublishedQuestion"
    }

    // MARK: - Requests

    static func requestConversion(examId: String, provider: AIProvider) -> [String: Any] {
        ["examId": examId, "provider": provider.rawValue]
    }

    static func requestBulk(scope: BulkConversionScope, provider: AIProvider, dryRun: Bool) -> [String: Any] {
        var payload: [String: Any] = ["provider": provider.rawValue, "dryRun": dryRun]
        switch scope {
        case let .course(id): payload["courseId"] = id
        case let .department(id): payload["departmentId"] = id
        }
        return payload
    }

    static func regenerate(jobId: String, provider: AIProvider) -> [String: Any] {
        ["jobId": jobId, "provider": provider.rawValue]
    }

    static func regenerateDraftQuestion(jobId: String, order: Int, provider: AIProvider) -> [String: Any] {
        ["jobId": jobId, "order": order, "provider": provider.rawValue]
    }

    /// A blank subject field is left out, so the server falls back to its own suggestion.
    static func publish(jobId: String, subjectId: String?, newSubjectName: String?) -> [String: Any] {
        var payload: [String: Any] = ["jobId": jobId]
        if let subjectId = trimmed(subjectId) { payload["subjectId"] = subjectId }
        if let name = trimmed(newSubjectName) { payload["newSubjectName"] = name }
        return payload
    }

    static func discard(jobId: String) -> [String: Any] {
        ["jobId": jobId]
    }

    static func updatePublishedQuestion(_ question: ExamQuestion) -> [String: Any] {
        var payload = contentFields(of: question)
        payload["questionId"] = question.id
        return payload
    }

    static func regeneratePublishedQuestion(questionId: String, provider: AIProvider) -> [String: Any] {
        ["questionId": questionId, "provider": provider.rawValue]
    }

    /// The editable content of a question, as Firestore/callable values (`text`, `speech`, `choices`, `answer`,
    /// `solution`); the only fields the draft-edit rules and `updatePublishedQuestion` accept.
    static func contentFields(of question: ExamQuestion) -> [String: Any] {
        var answer: [String: Any] = ["text": question.answer.text]
        if let choice = question.answer.choice { answer["choice"] = choice }
        if let speech = question.answer.speech { answer["speech"] = speech }
        return [
            "text": question.text,
            "speech": question.speech,
            "choices": question.choices.map { ["label": $0.label, "text": $0.text] },
            "answer": answer,
            "solution": question.solution,
        ]
    }

    // MARK: - Responses

    static func status(from data: Any?) -> ConversionStatus? {
        ((data as? [String: Any])?["status"] as? String).flatMap(ConversionStatus.init(rawValue:))
    }

    static func jobId(from data: Any?) -> String? {
        (data as? [String: Any])?["jobId"] as? String
    }

    static func bulkEstimate(from data: Any?) -> BulkConversionEstimate {
        let map = data as? [String: Any] ?? [:]
        return BulkConversionEstimate(
            examCount: max(0, (map["examCount"] as? NSNumber)?.intValue ?? 0),
            estimatedCostUsd: max(0, (map["estimatedCostUsd"] as? NSNumber)?.doubleValue ?? 0),
            jobIds: (map["jobIds"] as? [Any])?.compactMap { $0 as? String } ?? []
        )
    }

    static func publishResult(from data: Any?) -> PublishedExamResult? {
        let map = data as? [String: Any]
        guard let examId = map?["examId"] as? String, !examId.isEmpty else { return nil }
        return PublishedExamResult(examId: examId, questionCount: max(0, (map?["questionCount"] as? NSNumber)?.intValue ?? 0))
    }

    /// `aiUsage/<YYYY-MM>`: the month's spend, `costUsd` (a missing document is zero spend).
    static func monthlyUsage(month: String, data: [String: Any]?) -> AIMonthlyUsage {
        let cost = (data?["costUsd"] as? NSNumber)?.doubleValue ?? (data?["totalCostUsd"] as? NSNumber)?.doubleValue ?? 0
        return AIMonthlyUsage(month: month, costUsd: max(0, cost))
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

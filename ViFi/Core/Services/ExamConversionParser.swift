import Foundation

/// Turns a raw `examConversions/<jobId>` document into an `ExamConversion` (admin screens).
///
/// Pure and Firestore-free: callers convert `Timestamp` values to `Date` first. Shape (server-written,
/// `firebase/functions/conversions/schema.js`): `{ source: {type: legacy|submission, examId?, submissionId?},
/// kind: JPG|PDF, status, model: {provider, id}, attempts, error?, usage: {inputTokens, outputTokens, costUsd},
/// placement: {names: [String], ids: [String], subjectId?, subjectName?, originalTitle?, suggestedTitle?}, files: [{storagePath, order}],
/// createdAt, readyAt? }`.
nonisolated enum ExamConversionParser {
    static func conversion(id: String, data: [String: Any]) -> ExamConversion? {
        guard let source = source(from: data["source"]),
              let kind = (data["kind"] as? String).flatMap(ExamKind.init(rawValue:)),
              let status = (data["status"] as? String).flatMap(ConversionStatus.init(rawValue:)) else { return nil }
        let model = data["model"] as? [String: Any]
        let placement = data["placement"] as? [String: Any]
        return ExamConversion(
            id: id,
            source: source,
            kind: kind,
            status: status,
            provider: (model?["provider"] as? String).flatMap(AIProvider.init(rawValue:)),
            attempts: max(0, integer(data["attempts"]) ?? 0),
            error: (data["error"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            usage: usage(from: data["usage"]),
            placementNames: (placement?["names"] as? [Any])?.compactMap { $0 as? String } ?? [],
            createdAt: data["createdAt"] as? Date,
            readyAt: data["readyAt"] as? Date,
            files: files(from: data["files"]),
            suggestedSubjectId: nonEmpty(placement?["subjectId"]),
            suggestedSubjectName: nonEmpty(placement?["subjectName"]),
            originalTitle: originalTitle(placement),
            suggestedTitle: suggestedTitle(placement)
        )
    }

    /// `placement.originalTitle`, else the exam name of `placement.names` (jobs created before K28).
    private static func originalTitle(_ placement: [String: Any]?) -> String? {
        nonEmpty(placement?["originalTitle"]) ?? nonEmpty((placement?["names"] as? [Any])?.last)
    }

    /// `placement.suggestedTitle` when it is a list title (`null` = none); a job created before K28 has no such field,
    /// so the suggestion is computed from the original title, as the server does at publish.
    private static func suggestedTitle(_ placement: [String: Any]?) -> String? {
        guard let placement else { return nil }
        if placement.keys.contains("suggestedTitle") {
            return nonEmpty(placement["suggestedTitle"]).flatMap(ExamListTitle.parse)?.title
        }
        return originalTitle(placement).flatMap(ExamTitleParser.canonicalTitle)?.title
    }

    private static func files(from value: Any?) -> [SubmissionFileRef] {
        (value as? [[String: Any]] ?? []).compactMap { entry in
            guard let path = nonEmpty(entry["storagePath"]), let order = integer(entry["order"]) else { return nil }
            return SubmissionFileRef(storagePath: path, order: order)
        }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func source(from value: Any?) -> ConversionSource? {
        guard let map = value as? [String: Any] else { return nil }
        switch map["type"] as? String {
        case "legacy":
            guard let examId = map["examId"] as? String, !examId.isEmpty else { return nil }
            return .legacy(examId: examId)
        case "submission":
            guard let submissionId = map["submissionId"] as? String, !submissionId.isEmpty else { return nil }
            return .submission(submissionId: submissionId)
        default:
            return nil
        }
    }

    private static func usage(from value: Any?) -> ConversionUsage? {
        guard let map = value as? [String: Any] else { return nil }
        return ConversionUsage(
            inputTokens: max(0, integer(map["inputTokens"]) ?? 0),
            outputTokens: max(0, integer(map["outputTokens"]) ?? 0),
            costUsd: max(0, map["costUsd"] as? Double ?? 0)
        )
    }

    /// An integer stored as Int, or as a whole Double (counters can come back either way through the SDK).
    private static func integer(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        guard let double = value as? Double, double.isFinite, double.rounded() == double,
              abs(double) < Double(Int.max) else { return nil }
        return Int(double)
    }
}

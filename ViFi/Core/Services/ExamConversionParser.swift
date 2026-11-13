import Foundation

/// Turns a raw `examConversions/<jobId>` document into an `ExamConversion` (admin screens).
///
/// Pure and Firestore-free: callers convert `Timestamp` values to `Date` first. Shape (server-written,
/// `firebase/functions/conversions/schema.js`): `{ source: {type: legacy|submission, examId?, submissionId?},
/// kind: JPG|PDF, status, model: {provider, id}, attempts, error?, usage: {inputTokens, outputTokens, costUsd},
/// placement: {names: [String], ids: [String]}, createdAt, readyAt? }`.
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
            readyAt: data["readyAt"] as? Date
        )
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

import Foundation

/// A question label as the printed number alone (4.2.0): "Soru 1)", "S.1", "1." and "(1)" become "1"; "Soru 2a)",
/// "2 a" and "2-a" become "2a". Cards are titled "<label>. Soru", so a model that copied the paper's "Soru 1)" would
/// show "Soru 1). Soru". A label without a number ("Ek Soru") stays as it is (trimmed).
///
/// Mirrors `normalizeQuestionLabel` in `firebase/functions/conversions/schema.js` (same cases); the server normalizes
/// what it writes, `ExamQuestionParser` normalizes what it reads, so questions written earlier render too. Pure and
/// idempotent.
nonisolated enum QuestionLabel {
    static func normalize(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        // Same pattern as the server's.
        let pattern = /^[(\[]?\s*(?:(?:soru|s)\s*(?:no|numarası)?\s*[:.\-]?\s*)?(\d+)\s*[.\-)]?\s*([a-zçğıöşü])?\s*[)\].:\-]*$/
            .ignoresCase()
        guard let match = trimmed.wholeMatch(of: pattern) else { return trimmed }
        return String(match.output.1) + (match.output.2.map(String.init) ?? "")
    }
}

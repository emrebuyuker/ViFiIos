import Foundation

// The structured-exam question (4.2.0, "soruları tek tek görme"). The read side of the server contract in
// `firebase/functions/conversions/schema.js`; keep field names, limits and the id format in sync with it.
//
// Published questions live flat in Firestore `questions/<examId>-<nnn>` (read by +90 users and admins); drafts live
// under `examConversions/<jobId>/questions/<nnn>` and carry the review-only fields (`confidence`, `needsReview`).

/// One answer option of a multiple-choice question ("A", "B", …).
nonisolated struct QuestionChoice: Hashable, Codable, Sendable {
    let label: String
    /// Markdown + LaTeX (`$…$`, `$$…$$`).
    let text: String
}

/// A figure cropped from the original page, stored at `questionFigures/<jobId>/<nnn>-<k>.jpg`.
nonisolated struct QuestionFigure: Hashable, Codable, Sendable {
    let storagePath: String
    /// Pixel size, so the layout can reserve space before the image downloads; `nil` when unknown.
    let width: Int?
    let height: Int?
}

/// The answer revealed by "Cevabı Göster".
nonisolated struct QuestionAnswer: Hashable, Codable, Sendable {
    /// Markdown + LaTeX.
    let text: String
    /// The correct choice label for multiple choice.
    let choice: String?
    /// The answer as plain Turkish for VoiceOver; `nil` falls back to `text`.
    let speech: String?
}

/// A question as the app shows it (published or draft).
nonisolated struct ExamQuestion: Identifiable, Hashable, Sendable {
    /// Published: `<examId>-<nnn>` (permanent). Draft: `<nnn>`.
    let id: String
    let examId: String
    /// 1-based position in the exam.
    let order: Int
    /// The number printed on the paper ("1", "2a").
    let label: String
    /// Markdown + LaTeX, transcribed as written.
    let text: String
    /// Plain-text version of `text` for VoiceOver (formulas in words).
    let speech: String
    let choices: [QuestionChoice]
    let figures: [QuestionFigure]
    let answer: QuestionAnswer
    /// Worked solution steps (Markdown + LaTeX).
    let solution: [String]
    /// Topic slugs (practice mode, later).
    let topics: [String]
    /// 1 easy … 3 hard.
    let difficulty: Int
    /// Drafts only: how sure the model was (0…1) and whether it asks for a careful look.
    let confidence: Double?
    let needsReview: Bool
    let updatedAt: Date?
    /// Drafts only: the end of the server's regeneration lease while a single-question regeneration runs.
    var regeneratingUntil: Date?
    /// Drafts only: why the last single-question regeneration failed (cleared when a new one starts).
    var regenerationError: String?

    /// Whether a regeneration is running at `date` (the lease has not expired).
    func isRegenerating(at date: Date) -> Bool {
        regeneratingUntil.map { $0 > date } ?? false
    }
}

/// The AI provider an admin picks for a conversion action (owner decision K9). No default on the server.
nonisolated enum AIProvider: String, CaseIterable, Codable, Sendable {
    case claude
    case gemini

    /// The button / label text ("Claude ile ilerle").
    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .gemini: "Gemini"
        }
    }
}

/// Canonical exam types: the `ExamNameCatalog` ids (pinned by `ExamTitleParserTests`).
nonisolated enum ExamType: String, CaseIterable, Codable, Sendable {
    case vize
    case final
    case butunleme
    case mazeret
    case kisaSinav = "kisa-sinav"
    case yazOkulu = "yaz-okulu"
    case araSinav = "ara-sinav"
}

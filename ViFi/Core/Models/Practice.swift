import Foundation

// The practice mode's ("Sınava gir", 4.2.0) read side of the contract in the "PRACTICE MODE" block of
// `firebase/functions/conversions/schema.js`: the index doc `questionPoolIndex/<subjectId>`, the callable
// `nextPracticeQuestions` and its limits. Keep names and limits in sync with it.

/// Which pool a practice session draws from.
nonisolated enum PracticeScope: String, CaseIterable, Hashable, Sendable {
    /// This course only (`c-<courseId>`).
    case course
    /// The user's university, same subject (`u-<universityId>`).
    case university
    /// All universities, same subject (`tr`).
    case turkey = "tr"

    /// The key of this scope in an index document's per-type map.
    func poolKey(courseId: String, universityId: String?) -> String? {
        switch self {
        case .course: courseId.isEmpty ? nil : "c-\(courseId)"
        case .university: universityId.flatMap { $0.isEmpty ? nil : "u-\($0)" }
        case .turkey: "tr"
        }
    }
}

/// Limits shared with the server (`PRACTICE_*` in `schema.js`).
nonisolated enum PracticeLimits {
    /// The most seen ids the app sends as `exclude`.
    static let maxExclude = 300
    /// The most questions one call may ask for.
    static let maxBatch = 10
}

/// `questionPoolIndex/<subjectId>`: how many practice questions a subject has per exam type and scope.
nonisolated struct PracticePoolIndex: Equatable, Sendable {
    let subjectId: String
    let name: String?
    /// Counts per practice-eligible exam type, keyed by pool scope key (`tr`, `u-<id>`, `c-<id>`).
    let types: [ExamType: [String: Int]]

    /// Whether any scope of any type has a question (P4: one question is enough). Gates the "Sınava gir" entry.
    var hasPracticeQuestions: Bool {
        types.values.contains { $0.values.contains { $0 > 0 } }
    }

    /// The question count of `type` in `scope`; 0 when the scope is unknown.
    func count(type: ExamType, scope: PracticeScope, courseId: String, universityId: String?) -> Int {
        guard let key = scope.poolKey(courseId: courseId, universityId: universityId) else { return 0 }
        return types[type]?[key] ?? 0
    }
}

/// What the user picked in the setup: one pool of one subject.
nonisolated struct PracticeSelection: Hashable, Sendable {
    let subjectId: String
    let examType: ExamType
    let scope: PracticeScope
    let courseId: String
    let universityId: String?
    /// How many questions the pool holds (shown in the setup; informational).
    let poolCount: Int
}

/// One `nextPracticeQuestions` call.
nonisolated struct PracticeRequest: Equatable, Sendable {
    let selection: PracticeSelection
    /// Ids already seen in this session (at most `PracticeLimits.maxExclude`).
    let exclude: [String]
    /// 1…`PracticeLimits.maxBatch`.
    let count: Int
}

/// A question handed out by the server, with where it came from.
nonisolated struct PracticeQuestion: Identifiable, Hashable, Sendable {
    let question: ExamQuestion
    /// "2019 FİNAL"; `nil` when the server did not send it.
    let examTitle: String?
    let universityName: String?

    var id: String { question.id }

    /// "BOZOK ÜNİVERSİTESİ · 2019 FİNAL" (whatever parts are known), shown above the card.
    var sourceLine: String? {
        let parts = [universityName?.uppercased(with: Locale(identifier: "tr_TR")), examTitle]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The server's answer to a `nextPracticeQuestions` call.
nonisolated struct PracticeBatch: Equatable, Sendable {
    let questions: [PracticeQuestion]
    /// How many questions the pool holds in total.
    let poolSize: Int
    /// The free questions left today; `nil` for Premium (unlimited).
    let remainingToday: Int?
    /// The free daily limit stopped the call (no, or fewer, questions were delivered).
    let limitReached: Bool
}

nonisolated extension ExamType {
    /// The Turkish name of a practice-eligible type in the setup list ("Ara Sınav").
    var practiceTitle: String {
        switch self {
        case .vize: "Vize"
        case .araSinav: "Ara Sınav"
        case .final: "Final"
        case .butunleme: "Bütünleme"
        case .mazeret: "Mazeret"
        case .kisaSinav: "Kısa Sınav"
        case .tekDers: "Tek Ders"
        case .ekSinav: "Ek Sınav"
        case .muafiyet: "Muafiyet"
        case .seviyeTespit: "Seviye Tespit"
        case .uygulama: "Uygulama Sınavı"
        case .yazOkulu: "Yaz Okulu"
        case .laboratuvar: "Laboratuvar"
        case .odev: "Ödev"
        case .proje: "Proje"
        case .calismaSorulari: "Çalışma Soruları"
        case .cozumluSorular: "Çözümlü Sorular"
        }
    }

    /// The practice types in the order the setup lists them (the "Sınav Ekle" name list's order).
    static let practiceDisplayOrder: [ExamType] = [
        .vize, .araSinav, .final, .butunleme, .mazeret, .kisaSinav, .tekDers, .ekSinav,
        .muafiyet, .seviyeTespit, .uygulama, .yazOkulu,
    ]
}

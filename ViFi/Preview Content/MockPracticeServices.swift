#if DEBUG
import Foundation

extension ArchivePath {
    /// `TOPOLOJİ 1` in the mock archive: the one course with a subject and practice questions (it also holds the
    /// sample structured exam).
    static let mockPracticeLesson = ArchivePath(components: [
        "KOCAELİ ÜNİVERSİTESİ",
        "MÜHENDİSLİK FAKÜLTESİ",
        "MATEMATİK BÖLÜMÜ",
        "TOPOLOJİ 1",
    ])
}

/// A sample practice index for `.mockPracticeLesson`'s subject (a real `PracticeParser` is not needed: the model is
/// built directly). Final has all three scopes ("Üniversitem" follows the mock profile's university); vize has
/// one question only, to show a single-question pool (P4).
final class MockPracticeIndexReader: PracticeIndexReading {
    static let subjectId = "topoloji-1"

    func index(subjectId: String) async throws -> PracticePoolIndex? {
        guard subjectId == Self.subjectId else { return nil }
        try await Task.sleep(for: .milliseconds(100))
        return PracticePoolIndex(
            subjectId: subjectId,
            name: "Topoloji 1",
            types: [
                .final: [
                    "c-\(ArchivePath.mockPracticeLesson.components.last ?? "")": 3,
                    "u-\(UserProfile.mockDefault.universityId)": 2,
                    "tr": 3,
                ],
                .vize: ["tr": 1],
            ]
        )
    }
}

/// Serves the bundled sample questions as a practice pool and counts the free daily limit in memory, like the
/// server does (5 per day; Premium unlimited). Questions come in order (deterministic for UI tests).
final class MockPracticeService: PracticeServicing {
    static let dailyLimit = 5

    private let isSubscribed: Bool
    private let latency: Duration
    private var usedToday: Int

    init(isSubscribed: Bool = false, limitReached: Bool = false, latency: Duration = .milliseconds(150)) {
        self.isSubscribed = isSubscribed
        self.latency = latency
        usedToday = limitReached ? Self.dailyLimit : 0
    }

    func nextQuestions(_ request: PracticeRequest) async throws -> PracticeBatch {
        try await Task.sleep(for: latency)
        let pool = MockExamQuestionReader.sampleQuestions(examId: "mock-exam").map {
            PracticeQuestion(question: $0, examTitle: "2003 FİNAL", universityName: "Kocaeli Üniversitesi")
        }
        let unseen = pool.filter { !request.exclude.contains($0.id) }
        guard !isSubscribed else {
            return PracticeBatch(
                questions: Array(unseen.prefix(request.count)), poolSize: pool.count, remainingToday: nil, limitReached: false
            )
        }
        let allowance = max(0, Self.dailyLimit - usedToday)
        let delivered = Array(unseen.prefix(min(request.count, allowance)))
        usedToday += delivered.count
        let blocked = delivered.isEmpty && !unseen.isEmpty && allowance == 0
        return PracticeBatch(
            questions: delivered,
            poolSize: pool.count,
            remainingToday: max(0, Self.dailyLimit - usedToday),
            limitReached: blocked
        )
    }
}
#endif

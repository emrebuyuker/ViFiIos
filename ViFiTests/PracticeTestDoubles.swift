import Foundation
@testable import ViFi

/// A scripted `PracticeServicing`: returns the queued results in order and records every request.
final class StubPracticeService: PracticeServicing {
    enum Result {
        case batch(PracticeBatch)
        case failure(PracticeError)
    }

    var results: [Result]
    /// Used once `results` runs dry.
    var fallback: Result
    private(set) var requests: [PracticeRequest] = []

    init(results: [Result] = [], fallback: Result = .batch(PracticeFixture.batch(ids: [], remaining: nil))) {
        self.results = results
        self.fallback = fallback
    }

    func nextQuestions(_ request: PracticeRequest) async throws -> PracticeBatch {
        requests.append(request)
        let next = results.isEmpty ? fallback : results.removeFirst()
        switch next {
        case let .batch(batch): return batch
        case let .failure(error): throw error
        }
    }
}

/// An index reader that counts its reads.
final class StubPracticeIndexReader: PracticeIndexReading {
    var indexes: [String: PracticePoolIndex] = [:]
    var failure: PracticeError?
    private(set) var reads: [String] = []

    func index(subjectId: String) async throws -> PracticePoolIndex? {
        reads.append(subjectId)
        if let failure { throw failure }
        return indexes[subjectId]
    }
}

enum PracticeFixture {
    static let selection = PracticeSelection(
        subjectId: "topoloji-1", examType: .final, scope: .turkey, courseId: "topoloji-1-kocaeli",
        universityId: "kocaeli-universitesi", poolCount: 12
    )

    static func question(_ id: String) -> PracticeQuestion {
        let examId = String(id.dropLast(4))
        let order = Int(id.suffix(3)) ?? 1
        return PracticeQuestion(
            question: StructuredExamFixture.question(order: order, examId: examId),
            examTitle: "2019 FİNAL",
            universityName: "Bozok Üniversitesi"
        )
    }

    /// A batch of the questions with `ids` (`<examId>-<nnn>`); `remaining == nil` is Premium.
    static func batch(ids: [String], remaining: Int?, limitReached: Bool = false, poolSize: Int = 12) -> PracticeBatch {
        PracticeBatch(questions: ids.map(question), poolSize: poolSize, remainingToday: remaining, limitReached: limitReached)
    }

    static func index(types: [ExamType: [String: Int]]) -> PracticePoolIndex {
        PracticePoolIndex(subjectId: "topoloji-1", name: "Topoloji 1", types: types)
    }
}

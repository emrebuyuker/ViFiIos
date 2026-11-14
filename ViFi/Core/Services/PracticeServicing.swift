import Foundation

/// Reads a subject's practice-pool summary (`questionPoolIndex/<subjectId>`): one read tells the course screen
/// whether to offer "Sınava gir" and the setup which types and scopes have how many questions.
protocol PracticeIndexReading: AnyObject {
    /// The index of `subjectId`, or `nil` when the subject has no practice questions (no document).
    func index(subjectId: String) async throws -> PracticePoolIndex?
}

/// Hands out practice questions. The server counts the free daily limit, so questions are never read directly.
protocol PracticeServicing: AnyObject {
    func nextQuestions(_ request: PracticeRequest) async throws -> PracticeBatch
}

/// Practice failures, with Turkish messages for the UI.
nonisolated enum PracticeError: LocalizedError, Equatable {
    case offline
    case notSignedIn
    /// The server answered with something the app cannot read.
    case invalidResponse
    case unknown(message: String)

    var errorDescription: String? {
        switch self {
        case .offline:
            String(localized: "İnternet bağlantısı yok. Bağlantını kontrol edip tekrar dene.")
        case .notSignedIn:
            String(localized: "Soruları görmek için giriş yapmış olman gerekiyor.")
        case .invalidResponse:
            String(localized: "Sorular şu anda alınamadı. Lütfen daha sonra tekrar dene.")
        case let .unknown(message):
            message
        }
    }
}

/// An index reader with nothing to read: the environment's default.
final class EmptyPracticeIndexReader: PracticeIndexReading {
    func index(subjectId: String) async throws -> PracticePoolIndex? { nil }
}

/// A practice service that is not available: the environment's default where nothing wires one in.
final class UnavailablePracticeService: PracticeServicing {
    func nextQuestions(_ request: PracticeRequest) async throws -> PracticeBatch {
        throw PracticeError.invalidResponse
    }
}

/// Remembers each subject's index for the session, so reopening a course (or a second course of the same subject)
/// costs no further read. A failed read is not remembered; an absent index (`nil`) is.
final class CachingPracticeIndexReader: PracticeIndexReading {
    private let base: any PracticeIndexReading
    private var tasks: [String: Task<PracticePoolIndex?, any Error>] = [:]

    init(base: any PracticeIndexReading) {
        self.base = base
    }

    func index(subjectId: String) async throws -> PracticePoolIndex? {
        if let running = tasks[subjectId] {
            return try await running.value
        }
        let base = base
        let task = Task { try await base.index(subjectId: subjectId) }
        tasks[subjectId] = task
        do {
            return try await task.value
        } catch {
            tasks[subjectId] = nil
            throw error
        }
    }
}

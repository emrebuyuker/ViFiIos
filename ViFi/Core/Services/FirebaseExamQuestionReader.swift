@preconcurrency import FirebaseFirestore
import Foundation
import os

/// Reads an exam's published questions from Cloud Firestore (`vifi` database): `questions where examId == X order
/// by order`, about 10 to 30 reads per exam. Nothing prefetches questions (`ArchivePrefetcher` leaves them alone).
///
/// Documents are parsed by the Firestore-free `ExamQuestionParser`; `Timestamp` values are turned into `Date`s here,
/// before the parser sees them. Reading is gated by the rules to signed-in +90 users and admins. The query needs the
/// `questions (examId, order)` composite index (`firebase/firestore.indexes.json`).
final class FirebaseExamQuestionReader: ExamQuestionReading {
    private static let collection = "questions"

    private let firestore: Firestore

    init(firestore: Firestore = ViFiFirestore.shared) {
        self.firestore = firestore
    }

    func questions(examId: String) async throws -> [ExamQuestion] {
        let query = firestore.collection(Self.collection)
            .whereField(ExamQuestionParser.Field.examId, isEqualTo: examId)
            .order(by: ExamQuestionParser.Field.order)
        let snapshot: QuerySnapshot
        do {
            snapshot = try await query.getDocuments()
        } catch {
            throw Self.archiveError(from: error)
        }
        let rows = snapshot.documents.map { (id: $0.documentID, data: Self.convertingTimestamps($0.data())) }
        return ExamQuestionParser.questions(from: rows, examId: examId)
    }

    /// Replaces top-level `Timestamp` values with `Date`s, so the parser stays free of Firestore types.
    nonisolated static func convertingTimestamps(_ data: [String: Any]) -> [String: Any] {
        data.mapValues { ($0 as? Timestamp)?.dateValue() ?? $0 }
    }

    nonisolated static func archiveError(from error: any Error) -> ArchiveError {
        let nsError = error as NSError
        if nsError.domain == FirestoreErrorDomain, let code = FirestoreErrorCode.Code(rawValue: nsError.code) {
            switch code {
            case .permissionDenied: return .permissionDenied
            case .unavailable, .deadlineExceeded: return .offline
            case .notFound: return .notFound
            default: break
            }
        }
        Logger.archive.error("Firestore read of questions failed: \(String(describing: error), privacy: .public)")
        return .unknown(message: error.localizedDescription)
    }
}

/// An `ExamQuestionReading` with no questions: the environment's default where nothing reads them.
final class EmptyExamQuestionReader: ExamQuestionReading {
    func questions(examId: String) async throws -> [ExamQuestion] { [] }
}

@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseFunctions
import Foundation
import os

/// The admin AI-conversion workflow on Firebase: job and draft reads from Cloud Firestore (`vifi` database,
/// `examConversions`, `aiUsage`), the AI-running actions as admin-gated callables in `europe-west1`, and draft
/// edits as direct Firestore updates the rules allow (content fields + `editedBy` + `editedAt`).
final class FirebaseExamConversionService: ExamConversionServicing {
    private static let region = "europe-west1"
    private static let conversions = "examConversions"
    private static let drafts = "questions"
    private static let usage = "aiUsage"
    private static let listLimit = 100

    private let firestore: Firestore
    private let functions: Functions
    private let auth: any AuthServicing

    init(
        auth: any AuthServicing,
        firestore: Firestore = ViFiFirestore.shared,
        functions: Functions = Functions.functions(region: region)
    ) {
        self.auth = auth
        self.firestore = firestore
        self.functions = functions
    }

    func conversions(statuses: Set<ConversionStatus>) async throws -> [ExamConversion] {
        guard !statuses.isEmpty else { return [] }
        do {
            let snapshot = try await firestore.collection(Self.conversions)
                .whereField("status", in: statuses.map(\.rawValue))
                .order(by: "createdAt", descending: true)
                .limit(to: Self.listLimit)
                .getDocuments()
            return snapshot.documents.compactMap { document in
                ExamConversionParser.conversion(id: document.documentID, data: Self.convertingTimestamps(document.data()))
            }
        } catch {
            throw Self.conversionError(from: error)
        }
    }

    func draftQuestions(jobId: String) async throws -> [ExamQuestion] {
        do {
            let snapshot = try await firestore.collection(Self.conversions).document(jobId)
                .collection(Self.drafts).getDocuments()
            let docs = snapshot.documents.map { (id: $0.documentID, data: Self.convertingTimestamps($0.data())) }
            return ExamQuestionParser.questions(from: docs, examId: jobId)
        } catch {
            throw Self.conversionError(from: error)
        }
    }

    func requestConversion(examId: String, provider: AIProvider) async throws -> ExamConversion {
        let data = try await call(
            ExamConversionCalls.Name.requestConversion,
            ExamConversionCalls.requestConversion(examId: examId, provider: provider)
        )
        let jobId = ExamConversionCalls.jobId(from: data) ?? ConversionSource.legacy(examId: examId).jobId
        return ExamConversion(
            id: jobId, source: .legacy(examId: examId), kind: .images,
            status: ExamConversionCalls.status(from: data) ?? .queued, provider: provider, attempts: 0, error: nil,
            usage: nil, placementNames: [], createdAt: nil, readyAt: nil
        )
    }

    func regenerate(jobId: String, provider: AIProvider) async throws {
        _ = try await call(ExamConversionCalls.Name.regenerate, ExamConversionCalls.regenerate(jobId: jobId, provider: provider))
    }

    func regenerateQuestion(jobId: String, order: Int, provider: AIProvider) async throws {
        _ = try await call(
            ExamConversionCalls.Name.regenerateDraftQuestion,
            ExamConversionCalls.regenerateDraftQuestion(jobId: jobId, order: order, provider: provider)
        )
    }

    func saveDraftQuestion(jobId: String, question: ExamQuestion) async throws {
        guard let uid = auth.currentUser?.id else { throw ExamConversionError.permissionDenied }
        var fields = ExamConversionCalls.contentFields(of: question)
        // The edited draft is the admin's judgement now, so it no longer asks for a careful look.
        fields["needsReview"] = false
        fields["editedBy"] = uid
        fields["editedAt"] = FieldValue.serverTimestamp()
        let key = String(format: "%03d", question.order)
        do {
            try await firestore.collection(Self.conversions).document(jobId)
                .collection(Self.drafts).document(key).updateData(fields)
        } catch {
            throw Self.conversionError(from: error)
        }
    }

    func publish(jobId: String, subjectId: String?, newSubjectName: String?, examTitle: String?) async throws -> PublishedExamResult {
        let data = try await call(
            ExamConversionCalls.Name.publish,
            ExamConversionCalls.publish(
                jobId: jobId, subjectId: subjectId, newSubjectName: newSubjectName, examTitle: examTitle
            )
        )
        guard let result = ExamConversionCalls.publishResult(from: data) else {
            throw ExamConversionError.unknown(message: String(localized: "Sunucudan beklenmeyen bir yanıt geldi."))
        }
        return result
    }

    func discard(jobId: String) async throws {
        _ = try await call(ExamConversionCalls.Name.discard, ExamConversionCalls.discard(jobId: jobId))
    }

    func requestBulkConversion(scope: BulkConversionScope, provider: AIProvider, dryRun: Bool) async throws -> BulkConversionEstimate {
        let data = try await call(
            ExamConversionCalls.Name.requestBulk,
            ExamConversionCalls.requestBulk(scope: scope, provider: provider, dryRun: dryRun)
        )
        return ExamConversionCalls.bulkEstimate(from: data)
    }

    func monthlyUsage() async throws -> AIMonthlyUsage {
        let month = AIMonthlyUsage.monthKey(for: .now)
        do {
            let snapshot = try await firestore.collection(Self.usage).document(month).getDocument()
            return ExamConversionCalls.monthlyUsage(month: month, data: snapshot.data())
        } catch {
            throw Self.conversionError(from: error)
        }
    }

    func updatePublishedQuestion(_ question: ExamQuestion) async throws {
        _ = try await call(ExamConversionCalls.Name.updatePublishedQuestion, ExamConversionCalls.updatePublishedQuestion(question))
    }

    func regeneratePublishedQuestion(questionId: String, provider: AIProvider) async throws {
        _ = try await call(
            ExamConversionCalls.Name.regeneratePublishedQuestion,
            ExamConversionCalls.regeneratePublishedQuestion(questionId: questionId, provider: provider)
        )
    }

    // MARK: - Private

    /// Calls an admin callable and returns its raw response data.
    private func call(_ name: String, _ payload: sending [String: Any]) async throws -> sending Any? {
        do {
            return try await functions.httpsCallable(name).call(payload).data
        } catch {
            throw Self.conversionError(from: error)
        }
    }

    /// Top-level `Timestamp` values as `Date`, the shape the Firestore-free parsers expect.
    private static func convertingTimestamps(_ data: [String: Any]) -> [String: Any] {
        data.mapValues { ($0 as? Timestamp)?.dateValue() ?? $0 }
    }

    nonisolated static func conversionError(from error: any Error) -> any Error {
        if error is ExamConversionError || error is CancellationError { return error }
        let nsError = error as NSError
        if nsError.domain == FunctionsErrorDomain, let code = FunctionsErrorCode(rawValue: nsError.code) {
            switch code {
            case .permissionDenied, .unauthenticated: return ExamConversionError.permissionDenied
            case .notFound: return ExamConversionError.notFound
            case .resourceExhausted: return ExamConversionError.budgetExceeded
            case .failedPrecondition: return ExamConversionError.notAllowed(message: nsError.localizedDescription)
            case .invalidArgument: return ExamConversionError.invalidInput(message: nsError.localizedDescription)
            case .unavailable, .deadlineExceeded: return ExamConversionError.offline
            default: break
            }
        }
        if nsError.domain == FirestoreErrorDomain, let code = FirestoreErrorCode.Code(rawValue: nsError.code) {
            switch code {
            case .permissionDenied: return ExamConversionError.permissionDenied
            case .notFound: return ExamConversionError.notFound
            case .unavailable, .deadlineExceeded: return ExamConversionError.offline
            default: break
            }
        }
        if nsError.domain == NSURLErrorDomain { return ExamConversionError.offline }
        Logger.app.error("Exam conversion operation failed: \(String(describing: error), privacy: .public)")
        return ExamConversionError.unknown(message: error.localizedDescription)
    }
}

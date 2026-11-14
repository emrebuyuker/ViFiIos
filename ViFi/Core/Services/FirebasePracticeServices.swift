@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseFunctions
import Foundation
import os

/// Reads `questionPoolIndex/<subjectId>` from Cloud Firestore (`vifi` database): one document read. Written by the
/// server only; +90 users and admins read it. A missing document means the subject has no practice questions.
final class FirebasePracticeIndexReader: PracticeIndexReading {
    private static let collection = "questionPoolIndex"

    private let firestore: Firestore

    init(firestore: Firestore = ViFiFirestore.shared) {
        self.firestore = firestore
    }

    func index(subjectId: String) async throws -> PracticePoolIndex? {
        let snapshot: DocumentSnapshot
        do {
            snapshot = try await firestore.collection(Self.collection).document(subjectId).getDocument()
        } catch {
            throw FirebaseExamQuestionReader.archiveError(from: error)
        }
        guard let data = snapshot.data() else { return nil }
        return PracticeParser.index(from: data, subjectId: subjectId)
    }
}

/// Gets practice questions from the `nextPracticeQuestions` callable (europe-west1), which counts the free daily
/// limit per account. A Premium subscriber sends the current StoreKit entitlement's signed transaction as proof;
/// the server verifies it (no proof or an invalid one means the free rules).
final class FirebasePracticeService: PracticeServicing {
    private static let region = "europe-west1"
    private static let name = "nextPracticeQuestions"

    private let functions: Functions
    private let subscription: any SubscriptionServicing

    init(subscription: any SubscriptionServicing, functions: Functions = Functions.functions(region: region)) {
        self.subscription = subscription
        self.functions = functions
    }

    func nextQuestions(_ request: PracticeRequest) async throws -> PracticeBatch {
        let proof = await subscription.currentEntitlementJWS()
        let response: HTTPSCallableResult
        do {
            response = try await functions.httpsCallable(Self.name).call(Self.payload(for: request, proofJWS: proof))
        } catch {
            throw Self.practiceError(from: error)
        }
        guard let batch = PracticeParser.batch(from: response.data) else { throw PracticeError.invalidResponse }
        return batch
    }

    /// The callable's request body.
    nonisolated static func payload(for request: PracticeRequest, proofJWS: String?) -> [String: Any] {
        let selection = request.selection
        var body: [String: Any] = [
            "subjectId": selection.subjectId,
            "examType": selection.examType.rawValue,
            "scope": selection.scope.rawValue,
            "exclude": Array(request.exclude.suffix(PracticeLimits.maxExclude)),
            "count": min(max(request.count, 1), PracticeLimits.maxBatch),
        ]
        switch selection.scope {
        case .course: body["courseId"] = selection.courseId
        case .university: body["universityId"] = selection.universityId
        case .turkey: break
        }
        if let proofJWS, !proofJWS.isEmpty {
            body["subscriptionProof"] = ["platform": "ios", "jws": proofJWS]
        }
        return body
    }

    /// Maps a Functions/transport error to a `PracticeError`, logging the original.
    nonisolated static func practiceError(from error: any Error) -> PracticeError {
        let nsError = error as NSError
        if nsError.domain == FunctionsErrorDomain, let code = FunctionsErrorCode(rawValue: nsError.code) {
            switch code {
            case .unauthenticated, .permissionDenied: return .notSignedIn
            case .unavailable, .deadlineExceeded: return .offline
            default: break
            }
        }
        if nsError.domain == NSURLErrorDomain { return .offline }
        Logger.app.error("Practice questions failed: \(String(describing: error), privacy: .public)")
        return .unknown(message: error.localizedDescription)
    }
}

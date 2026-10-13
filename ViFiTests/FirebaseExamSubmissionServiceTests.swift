import Foundation
import Testing
@testable import ViFi

/// Exercises the Firebase-free parts of the live submission service: its error mapping. The Firestore/Storage
/// I/O itself is covered by the emulator rule tests and simulator QA, not here.
@Suite("FirebaseExamSubmissionService")
struct FirebaseExamSubmissionServiceTests {
    @Test("An ExamSubmissionError passes through unchanged")
    func passesThroughSubmissionError() {
        #expect(FirebaseExamSubmissionService.submissionError(from: ExamSubmissionError.notSignedIn) == .notSignedIn)
        #expect(FirebaseExamSubmissionService.submissionError(from: ExamSubmissionError.invalidSubmission) == .invalidSubmission)
    }

    @Test("A URL loading error maps to offline")
    func urlErrorMapsToOffline() {
        #expect(FirebaseExamSubmissionService.submissionError(from: URLError(.notConnectedToInternet)) == .offline)
        #expect(FirebaseExamSubmissionService.submissionError(from: URLError(.timedOut)) == .offline)
    }

    @Test("An unrecognised error maps to a generic unknown error")
    func unknownErrorMapsToUnknown() {
        let mapped = FirebaseExamSubmissionService.submissionError(from: NSError(domain: "SomeOther", code: 42))
        guard case .unknown = mapped else {
            Issue.record("Expected .unknown, got \(mapped)")
            return
        }
    }
}

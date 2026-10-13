import Foundation
import Testing
@testable import ViFi

@MainActor
@Suite("ModerationViewModel")
struct ModerationViewModelTests {
    @Test("Loading lists the pending submissions")
    func loadsPending() async {
        let service = StubModerationService(pending: [
            Fixture.submissionRecord(id: "a"),
            Fixture.submissionRecord(id: "b"),
        ])
        let viewModel = ModerationViewModel(service: service)

        await viewModel.loadIfNeeded()

        #expect(viewModel.state.value?.map(\.id) == ["a", "b"])
    }

    @Test("A failed load surfaces an error")
    func failedLoad() async {
        let viewModel = ModerationViewModel(service: ThrowingModerationService())

        await viewModel.loadIfNeeded()

        if case .failed = viewModel.state {} else {
            Issue.record("Expected a failed state")
        }
    }

    @Test("Approving removes the submission and reports the result")
    func approveRemoves() async {
        let service = StubModerationService(pending: [Fixture.submissionRecord(id: "a"), Fixture.submissionRecord(id: "b")])
        service.approveReplies = [.success(ApprovalResult(tier: .newUniversity, coins: 500, publishedExamId: "exam-a"))]
        let viewModel = ModerationViewModel(service: service)
        await viewModel.loadIfNeeded()

        let outcome = await viewModel.approve(Fixture.submissionRecord(id: "a"))

        #expect(outcome == .approved(ApprovalResult(tier: .newUniversity, coins: 500, publishedExamId: "exam-a")))
        #expect(viewModel.state.value?.map(\.id) == ["b"])
        #expect(service.approvedIDs == ["a"])
    }

    @Test("A failed approval keeps the submission in the list")
    func approveFailureKeeps() async {
        let service = StubModerationService(pending: [Fixture.submissionRecord(id: "a")])
        service.approveReplies = [.failure(ModerationError.offline)]
        let viewModel = ModerationViewModel(service: service)
        await viewModel.loadIfNeeded()

        let outcome = await viewModel.approve(Fixture.submissionRecord(id: "a"))

        if case .failed = outcome {} else {
            Issue.record("Expected a failed outcome")
        }
        #expect(viewModel.state.value?.map(\.id) == ["a"])
    }

    @Test("Rejecting removes the submission and records the reason")
    func rejectRemoves() async {
        let service = StubModerationService(pending: [Fixture.submissionRecord(id: "a"), Fixture.submissionRecord(id: "b")])
        let viewModel = ModerationViewModel(service: service)
        await viewModel.loadIfNeeded()

        let message = await viewModel.reject(Fixture.submissionRecord(id: "a"), reason: "Okunmuyor")

        #expect(message == nil)
        #expect(viewModel.state.value?.map(\.id) == ["b"])
        #expect(service.rejectedReasons.first?.id == "a")
        #expect(service.rejectedReasons.first?.reason == "Okunmuyor")
    }

    @Test("A failed rejection returns the error message and keeps the submission")
    func rejectFailure() async {
        let service = StubModerationService(pending: [Fixture.submissionRecord(id: "a")])
        service.rejectError = ModerationError.permissionDenied
        let viewModel = ModerationViewModel(service: service)
        await viewModel.loadIfNeeded()

        let message = await viewModel.reject(Fixture.submissionRecord(id: "a"), reason: nil)

        #expect(message == ModerationError.permissionDenied.userMessage)
        #expect(viewModel.state.value?.map(\.id) == ["a"])
    }
}

/// A moderation service whose list load always fails, for the error-path test.
private final class ThrowingModerationService: ModerationServicing {
    func pendingSubmissions() async throws -> [ExamSubmissionRecord] {
        throw ModerationError.offline
    }
    func approve(_ record: ExamSubmissionRecord) async throws -> ApprovalResult {
        throw ModerationError.offline
    }
    func reject(_ record: ExamSubmissionRecord, reason: String?) async throws {
        throw ModerationError.offline
    }
    func deleteExam(at path: ArchivePath) async throws {
        throw ModerationError.offline
    }
}

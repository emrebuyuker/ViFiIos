import Foundation
import Observation

/// The result of an approval attempt in the UI.
nonisolated enum ApprovalOutcome: Equatable {
    case approved(ApprovalResult)
    case failed(String)
}

/// Drives the admin moderation queue: loads the pending submissions, and approves or rejects one, removing it
/// from the list on success. Approving credits the owner and hands the exam to the AI conversion; the heavy lifting is in
/// `ModerationServicing`.
@Observable
final class ModerationViewModel {
    private(set) var state: Loadable<[ExamSubmissionRecord]> = .loading

    @ObservationIgnored private let service: any ModerationServicing
    @ObservationIgnored private var hasLoaded = false

    init(service: any ModerationServicing) {
        self.service = service
    }

    /// Loads the queue once per screen; a cancelled load is retried on reappearance.
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await load()
    }

    func refresh() async {
        await load()
    }

    /// First approval of `record` with the AI `provider` the admin picked: on success removes it from the queue and
    /// reports the result (coins + tier); on failure reports the message so the detail can show it.
    func approve(_ record: ExamSubmissionRecord, provider: AIProvider) async -> ApprovalOutcome {
        do {
            let result = try await service.approve(record, provider: provider)
            remove(record)
            return .approved(result)
        } catch {
            return .failed(error.userMessage)
        }
    }

    /// The existing exam `record` duplicates (K22), or `nil`; the detail screen warns when this is set.
    func duplicateExamId(for record: ExamSubmissionRecord) async -> String? {
        await service.duplicateExamId(of: record)
    }

    /// Rejects `record` with an optional reason; on success removes it from the queue. Returns the error message
    /// on failure, `nil` on success.
    func reject(_ record: ExamSubmissionRecord, reason: String?) async -> String? {
        do {
            try await service.reject(record, reason: reason)
            remove(record)
            return nil
        } catch {
            return error.userMessage
        }
    }

    private func load() async {
        if state.value == nil {
            state = .loading
        }
        do {
            state = .loaded(try await service.pendingSubmissions())
        } catch is CancellationError {
            hasLoaded = false
        } catch {
            state = .failed(message: error.userMessage)
        }
    }

    private func remove(_ record: ExamSubmissionRecord) {
        guard var records = state.value else { return }
        records.removeAll { $0.id == record.id }
        state = .loaded(records)
    }
}

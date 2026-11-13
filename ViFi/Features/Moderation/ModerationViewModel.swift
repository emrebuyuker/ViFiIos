import Foundation
import Observation

/// The result of an approval attempt in the UI.
nonisolated enum ApprovalOutcome: Equatable {
    case approved(ApprovalResult)
    case failed(String)
}

/// What is known about a submission owner while the moderator reads the queue.
nonisolated enum SubmitterState: Equatable {
    case loading
    case loaded(SubmitterInfo)
    /// The profile does not exist (for example the account was deleted).
    case missing
    case failed
}

/// Drives the admin moderation queue: loads the pending submissions, and approves or rejects one, removing it
/// from the list on success. Approving credits the owner and hands the exam to the AI conversion; the heavy lifting is in
/// `ModerationServicing`.
@Observable
final class ModerationViewModel {
    private(set) var state: Loadable<[ExamSubmissionRecord]> = .loading

    /// Submitter lookups by owner uid; a uid is read once and shared by every row and detail that needs it.
    private(set) var submitters: [String: SubmitterState] = [:]

    @ObservationIgnored private let service: any ModerationServicing
    @ObservationIgnored private let submitterReader: any SubmitterProfileReading
    @ObservationIgnored private var hasLoaded = false

    init(service: any ModerationServicing, submitterReader: any SubmitterProfileReading = NoopSubmitterProfileReader()) {
        self.service = service
        self.submitterReader = submitterReader
    }

    /// Looks up the owner `uid` once (lazily, per visible row); a failed lookup is retried the next time it is asked.
    /// Never blocks the queue: approve and reject do not depend on it.
    func loadSubmitter(uid: String) async {
        switch submitters[uid] {
        case .loading, .loaded, .missing: return
        case .failed, nil: break
        }
        submitters[uid] = .loading
        do {
            if let info = try await submitterReader.submitter(uid: uid) {
                submitters[uid] = .loaded(info)
            } else {
                submitters[uid] = .missing
            }
        } catch is CancellationError {
            submitters[uid] = nil
        } catch {
            submitters[uid] = .failed
        }
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

import Foundation
import Observation

/// Which jobs a conversion list shows.
nonisolated enum ConversionListKind: Equatable {
    /// Drafts waiting for the second approval ("Hazır sınavlar").
    case ready
    /// Jobs that gave up after their retries ("Başarısız işler").
    case failed

    var statuses: Set<ConversionStatus> {
        switch self {
        case .ready: [.ready]
        case .failed: [.failed]
        }
    }
}

/// Drives the admin's job lists: loads the jobs of one kind and restarts a failed one with the provider the admin
/// picked (K9; there is no default). A restarted job leaves the list because it is queued again.
@Observable
final class ConversionJobsViewModel {
    let kind: ConversionListKind
    private(set) var state: Loadable<[ExamConversion]> = .loading
    private(set) var isWorking = false
    /// The last failed action, shown above the list.
    private(set) var actionError: String?

    @ObservationIgnored private let service: any ExamConversionServicing
    @ObservationIgnored private var hasLoaded = false

    init(kind: ConversionListKind, service: any ExamConversionServicing) {
        self.kind = kind
        self.service = service
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await load()
    }

    func refresh() async {
        await load()
    }

    /// Re-reads an already shown list (the admin came back from a review that published, discarded or re-queued a
    /// job); does nothing while the first load is still pending.
    func refreshIfLoaded() async {
        guard state.value != nil else { return }
        await load()
    }

    /// Restarts a failed job (or re-runs a ready one) with `provider`; returns whether the server accepted it.
    @discardableResult
    func restart(_ job: ExamConversion, provider: AIProvider) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        actionError = nil
        defer { isWorking = false }
        do {
            try await service.regenerate(jobId: job.id, provider: provider)
            remove(job)
            return true
        } catch {
            actionError = error.userMessage
            return false
        }
    }

    private func load() async {
        if state.value == nil { state = .loading }
        do {
            let jobs = try await service.conversions(statuses: kind.statuses)
            state = .loaded(jobs)
        } catch is CancellationError {
            hasLoaded = false
        } catch {
            state = .failed(message: error.userMessage)
        }
    }

    private func remove(_ job: ExamConversion) {
        guard var jobs = state.value else { return }
        jobs.removeAll { $0.id == job.id }
        state = .loaded(jobs)
    }
}

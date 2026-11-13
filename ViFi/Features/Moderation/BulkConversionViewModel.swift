import Foundation
import Observation

/// Drives the bulk conversion screen (K12b): pick a course or department and an AI provider, get a dry-run
/// estimate against the month's $50 budget, confirm, and queue the unconverted exams.
@Observable
final class BulkConversionViewModel {
    enum Phase: Equatable {
        case idle
        case estimating
        /// A dry run came back; waiting for the admin's confirmation.
        case estimated(BulkConversionEstimate)
        case queueing
        case queued(BulkConversionEstimate)
    }

    private(set) var phase: Phase = .idle
    private(set) var usage: AIMonthlyUsage?
    private(set) var errorMessage: String?

    /// What to convert; changing it (or the provider) invalidates a previous estimate.
    var scope: BulkConversionScope? {
        didSet { if oldValue != scope { resetEstimate() } }
    }

    /// No default: the admin picks Claude or Gemini every time (K9).
    var provider: AIProvider? {
        didSet { if oldValue != provider { resetEstimate() } }
    }

    @ObservationIgnored private let service: any ExamConversionServicing

    init(service: any ExamConversionServicing) {
        self.service = service
    }

    var canEstimate: Bool {
        scope != nil && provider != nil && (phase == .idle || phase.isFinished)
    }

    /// The estimate would push this month past the cap; the confirmation says so but the server decides.
    var estimateExceedsBudget: Bool {
        guard case let .estimated(estimate) = phase, let usage else { return false }
        return usage.exceedsCap(adding: estimate.estimatedCostUsd)
    }

    func loadUsage() async {
        usage = try? await service.monthlyUsage()
    }

    func estimate() async {
        guard canEstimate, let scope, let provider else { return }
        phase = .estimating
        errorMessage = nil
        do {
            let estimate = try await service.requestBulkConversion(scope: scope, provider: provider, dryRun: true)
            phase = .estimated(estimate)
        } catch {
            phase = .idle
            errorMessage = error.userMessage
        }
    }

    /// Queues the exams of the confirmed estimate.
    func confirm() async {
        guard case .estimated = phase, let scope, let provider else { return }
        phase = .queueing
        errorMessage = nil
        do {
            let result = try await service.requestBulkConversion(scope: scope, provider: provider, dryRun: false)
            phase = .queued(result)
            await loadUsage()
        } catch {
            phase = .idle
            errorMessage = error.userMessage
        }
    }

    private func resetEstimate() {
        if case .estimated = phase { phase = .idle }
        if case .queued = phase { phase = .idle }
    }
}

extension BulkConversionViewModel.Phase {
    var isFinished: Bool {
        switch self {
        case .estimated, .queued: true
        case .idle, .estimating, .queueing: false
        }
    }
}

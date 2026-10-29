import Foundation
import Observation
import os

/// The signed-in user's campaign-notification consent, kept live for the permission flow and Account.
///
/// `RootView` drives it: `observe(uid:)` in a `.task(id:)` on the signed-in branch follows the record, and
/// `reset()` clears it on sign-out. Mirrors `CoinWalletStore`. Three states matter, and none is guessed from
/// another: not loaded yet, never answered (`consent == nil`), and the user's answer.
@Observable
final class NotificationSettingsStore {
    /// Whether the record has been read for the current user.
    enum Availability: Equatable {
        /// Not delivered yet.
        case loading
        /// Delivered (the user may still never have answered).
        case ready
        /// Could not be read; the toggle must not pretend to know the answer.
        case unavailable
    }

    private(set) var consent: NotificationConsent?
    private(set) var availability: Availability = .loading

    @ObservationIgnored private let service: any NotificationSettingsServicing
    @ObservationIgnored private let saveTimeout: Duration
    @ObservationIgnored private var userId: String?

    /// - Parameter saveTimeout: How long a write is awaited. Offline, Firestore queues it and acknowledges only
    ///   once back online; the answer is already in the local cache, so waiting longer would only hang the UI.
    init(service: any NotificationSettingsServicing, saveTimeout: Duration = .seconds(4)) {
        self.service = service
        self.saveTimeout = saveTimeout
    }

    /// Whether campaigns are allowed. `false` until the user opts in.
    var marketingEnabled: Bool { consent?.marketing ?? false }

    /// Whether the user has answered at all (on any device).
    var hasAnswered: Bool { consent != nil }

    /// Whether the record has been read (so `hasAnswered` can be trusted).
    var isLoaded: Bool { availability == .ready }

    /// Follows the record for `uid` until the calling task is cancelled.
    func observe(uid: String) async {
        if userId != uid {
            consent = nil
            availability = .loading
        }
        userId = uid
        for await feed in service.consentChanges(uid: uid) {
            switch feed {
            case let .success(consent):
                self.consent = consent
                availability = .ready
            case .failure:
                availability = .unavailable
            }
        }
    }

    /// Clears the answer on sign-out, so the next user never inherits it.
    func reset() {
        consent = nil
        availability = .loading
        userId = nil
    }

    /// Waits until the record has been read (or could not be), for at most `timeout`. Returns whether it is
    /// loaded. Used before offering a consent the user may already have given on another device.
    func waitUntilLoaded(timeout: Duration = .seconds(5)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while availability == .loading, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
            guard !Task.isCancelled else { break }
        }
        return isLoaded
    }

    /// Records the user's answer. The new value shows at once; it is put back when the write fails. A write that
    /// is not acknowledged in time (offline) counts as saved: the service has queued it.
    /// - Returns: Whether the answer was recorded.
    @discardableResult
    func setMarketing(_ enabled: Bool, source: NotificationConsentSource) async -> Bool {
        guard let userId else { return false }
        let previous = consent
        consent = NotificationConsent(marketing: enabled)

        let service = service
        let outcome = FirstOutcome<Bool>()
        let write = Task {
            do {
                try await service.setMarketing(enabled, source: source, uid: userId)
                outcome.resolve(.success(true))
            } catch {
                outcome.resolve(.failure(error))
            }
        }
        let timer = Task { [saveTimeout] in
            try await Task.sleep(for: saveTimeout)
            outcome.resolve(.success(false))
        }
        defer { timer.cancel() }

        do {
            let acknowledged = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
                    outcome.attach(continuation)
                }
            } onCancel: {
                outcome.resolve(.failure(CancellationError()))
                write.cancel()
            }
            if !acknowledged {
                Logger.app.notice("Saving the campaign consent was not acknowledged in time; it stays queued")
            }
            return true
        } catch {
            let reason = String(describing: error)
            Logger.app.notice("Saving the campaign consent failed: \(reason, privacy: .public)")
            consent = previous
            return false
        }
    }
}

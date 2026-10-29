import Foundation
import Observation

/// Drives the admin notification history: loads the latest sent, scheduled and automatic notifications, and
/// cancels a scheduled one before it goes out.
@Observable
final class NotificationHistoryViewModel {
    private(set) var state: Loadable<[SentNotification]> = .loading
    /// The notification whose cancellation is in flight; blocks a second tap and a refresh race.
    private(set) var cancelingId: String?
    private(set) var errorMessage: String?

    @ObservationIgnored private let service: any NotificationAdminServicing
    @ObservationIgnored private var hasLoaded = false

    init(service: any NotificationAdminServicing) {
        self.service = service
    }

    /// Loads the list once per screen; a cancelled load is retried on reappearance.
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await load()
    }

    func refresh() async {
        errorMessage = nil
        await load()
    }

    /// Cancels `notification` (only a scheduled one can be) and reloads the list, so the row shows its new status.
    func cancel(_ notification: SentNotification) async {
        guard cancelingId == nil, notification.status == .scheduled else { return }
        cancelingId = notification.id
        errorMessage = nil
        defer { cancelingId = nil }
        do {
            try await service.cancel(notificationId: notification.id)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.userMessage
            // It may have gone out meanwhile; the reload shows where it really is.
            if (error as? NotificationAdminError) == .notCancelable {
                await load()
            }
            return
        }
        await load()
    }

    private func load() async {
        if state.value == nil {
            state = .loading
        }
        do {
            state = .loaded(try await service.history())
        } catch is CancellationError {
            hasLoaded = false
        } catch {
            // A failed refresh keeps the rows already on screen and reports the problem above them.
            if state.value == nil {
                state = .failed(message: error.userMessage)
            } else {
                errorMessage = error.userMessage
            }
        }
    }
}

import Observation

/// Opens the notification inbox, from the bell or from a tapped push, and says which entry to highlight.
///
/// A tap on a push (`AppDelegate`) cannot open anything by itself: on a cold start the app is still behind its
/// gates (required update, sign-in, profile completion), and on a warm start a sheet may be in the way. It only
/// leaves a request — `receive(notificationId:)` — which stays pending until a screen that is past the gates
/// calls `deliverPending()` (`HomeView`). A push belongs to the account that received it, so signing out drops the
/// request, and so does a tap made while signed out when someone then signs in (`sessionDidChange(from:to:)`).
@Observable
final class NotificationRouter {
    /// A tapped push waiting to be shown.
    struct Request: Equatable {
        /// The notification to highlight; `nil` for a push that carries none (the inbox just opens).
        let notificationId: String?
    }

    /// The tap waiting for the app to get past its gates; `nil` when there is none.
    private(set) var pending: Request?
    /// Whether the inbox sheet is up. Bound to the sheet, so the system's swipe-down also resets it.
    var isInboxPresented = false
    /// The entry the inbox scrolls to and highlights (set by a push; cleared when the inbox goes away).
    private(set) var highlightedId: String?

    /// A push was tapped. Keeps it until `deliverPending()`.
    func receive(notificationId: String?) {
        pending = Request(notificationId: notificationId)
    }

    /// Shows the pending tap, if any: opens the inbox and highlights the entry. Call only from a screen that is
    /// past every gate.
    func deliverPending() {
        guard let request = pending else { return }
        pending = nil
        highlightedId = request.notificationId
        isInboxPresented = true
    }

    /// Opens the inbox from the bell, without a highlight.
    func openInbox() {
        highlightedId = nil
        isInboxPresented = true
    }

    /// The inbox went away: nothing is highlighted any more.
    func inboxDidDismiss() {
        highlightedId = nil
    }

    /// Keeps the pending tap in step with the session (`RootView`, on every change of `SessionStore.state`).
    ///
    /// Signing out drops everything. A tap that arrives while already signed out belongs to no account, so it is
    /// dropped when the state goes signed out → signed in. A cold start is different: the tap that launched the
    /// app waits through `unknown` and must survive into `signedIn`.
    func sessionDidChange(from old: SessionStore.State, to new: SessionStore.State) {
        switch (old, new) {
        case (_, .signedOut):
            reset()
        case (.signedOut, .signedIn):
            pending = nil
        default:
            break
        }
    }

    /// Forgets the pending tap and closes the inbox (sign-out).
    func reset() {
        pending = nil
        highlightedId = nil
        isInboxPresented = false
    }
}

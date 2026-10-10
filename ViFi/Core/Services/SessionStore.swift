import Foundation
import Observation

/// Whether a user is signed in; `RootView` shows the login screen or the archive accordingly.
@Observable
final class SessionStore {
    enum State: Equatable {
        /// The stored session has not been restored yet (briefly, at launch).
        case unknown
        case signedOut
        case signedIn(AuthUser)
    }

    private(set) var state: State

    @ObservationIgnored private let auth: any AuthServicing

    init(auth: any AuthServicing) {
        self.auth = auth
        state = auth.currentUser.map(State.signedIn) ?? .unknown
    }

    /// The signed-in user, if any.
    var user: AuthUser? {
        if case let .signedIn(user) = state { user } else { nil }
    }

    /// Follows sign-ins and sign-outs until the calling task is cancelled (`RootView`'s `.task`).
    func observeUserChanges() async {
        for await user in auth.userChanges() {
            let newState = user.map(State.signedIn) ?? .signedOut
            if newState != state {
                state = newState
            }
        }
    }
}

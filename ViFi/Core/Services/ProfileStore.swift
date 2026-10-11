import Foundation
import Observation

/// Whether the signed-in user has completed their profile; `RootView` shows the completion screen or the
/// archive accordingly.
///
/// `RootView` drives this from the `.signedIn` branch (`load(uid:)` in a `.task(id:)`), and resets it on
/// sign-out. The completion and edit screens call `update(_:)` after a successful save, so the gate opens
/// without a second read.
@Observable
final class ProfileStore {
    enum State: Equatable {
        /// The profile has not been read yet (briefly, after signing in).
        case loading
        /// No profile stored yet: the completion screen is shown.
        case absent
        case present(UserProfile)
        /// The read failed; the user is offered a retry rather than being forced to re-enter a profile.
        case failed(String)
    }

    private(set) var state: State = .loading

    @ObservationIgnored private let service: any ProfileServicing
    /// The uid the current state was loaded for, so re-reading the same user does not flash the spinner.
    @ObservationIgnored private var loadedUID: String?

    init(service: any ProfileServicing) {
        self.service = service
    }

    /// The loaded profile, if any.
    var profile: UserProfile? {
        if case let .present(profile) = state { profile } else { nil }
    }

    /// Reads the profile for `uid`. Keeps a profile already loaded for the same user visible while it
    /// re-reads, so the gate does not flicker; cancellation leaves the current state untouched.
    func load(uid: String) async {
        if !(loadedUID == uid && profile != nil) {
            state = .loading
        }
        do {
            let profile = try await service.loadProfile(uid: uid)
            loadedUID = uid
            state = profile.map(State.present) ?? .absent
        } catch is CancellationError {
            // A newer load (or sign-out) superseded this one; leave the state to it.
        } catch {
            loadedUID = uid
            state = .failed(error.userMessage)
        }
    }

    /// Reflects a profile the user just saved, opening the gate without a reload.
    func update(_ profile: UserProfile) {
        state = .present(profile)
    }

    /// Clears the state on sign-out, so the next user starts from a clean read.
    func reset() {
        state = .loading
        loadedUID = nil
    }
}

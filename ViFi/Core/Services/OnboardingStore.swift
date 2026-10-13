import Foundation
import Observation

/// Tracks whether the first-launch onboarding tour has been seen, persisting the flag per device.
///
/// The tour is informational and shown once: `isPresenting` starts `true` on a fresh install and stays `true`
/// until the user finishes or skips it (`markSeen()`), after which it never shows again. The flag is per
/// device, not per user: like the recently-viewed list it lives in `UserDefaults`, so it is deliberately kept
/// out of the profile and the sign-out reset. Replaying the tour from the About screen does not touch this
/// flag — that path presents the tour view directly.
@Observable
final class OnboardingStore {
    // Bump the version suffix to show the tour again after a major redesign: the old key is then ignored and
    // the tour simply shows once more, rather than relying on a value written by an earlier schema.
    private static let storageKey = "onboarding.tour.v1"

    /// Whether the first-launch tour should be presented now. Drives the `fullScreenCover` in `RootView`.
    var isPresenting: Bool

    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isPresenting = !defaults.bool(forKey: Self.storageKey)
    }

    /// Records that the tour has been seen (persisted across launches) and dismisses it.
    func markSeen() {
        defaults.set(true, forKey: Self.storageKey)
        isPresenting = false
    }

    #if DEBUG
    /// Seeds the persisted "seen" flag, for mock / UI-test setup (the tour then starts hidden unless forced).
    static func seed(seen: Bool, into defaults: UserDefaults) {
        defaults.set(seen, forKey: storageKey)
    }
    #endif
}

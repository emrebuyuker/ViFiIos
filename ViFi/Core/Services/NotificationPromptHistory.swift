import Foundation

/// What this device has already shown of the notification permission flow, and when the user said no: the
/// schedule behind the contextual re-asks (NOTIFICATIONS.md §1.1).
///
/// Per device, not per user (like the recents and the onboarding flag): it lives in `UserDefaults` and is not
/// cleared on sign-out. The rules it keeps:
/// - the first offer of each step happens once;
/// - after a "no" (step 1/2 declined or refused by the system, step 2/2 declined) the step may be offered **once
///   more**, no sooner than `reaskDelay` after the first "no" (the callers pick the moment: after a submission for
///   the permission, when the inbox opens for the consent);
/// - after that only Account › Bildirim Ayarları.
///
/// A value type over `UserDefaults` with an injected clock, so the timing is tested without waiting.
struct NotificationPromptHistory {
    /// The shortest time between a first "no" and its one re-ask.
    static let reaskDelay: TimeInterval = 30 * 24 * 60 * 60

    // Bump a suffix on an incompatible change: the old key is then ignored. (`primingOffered` keeps its
    // original key, so a device that saw the old pre-permission screen is not shown the new one again.)
    private enum Key {
        static let primingOffered = "notifications.primingOffered.v1"
        static let permissionDeclinedAt = "notifications.permissionDeclinedAt.v1"
        static let permissionReaskShown = "notifications.permissionReaskShown.v1"
        static let consentOffered = "notifications.consentOffered.v1"
        static let consentDeclinedAt = "notifications.consentDeclinedAt.v1"
        static let consentReaskShown = "notifications.consentReaskShown.v1"
    }

    private let defaults: UserDefaults
    private let now: () -> Date

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
    }

    // MARK: - Step 1/2: the permission

    /// Whether the first offer of the permission step has been shown on this device.
    var hasOfferedPriming: Bool { defaults.bool(forKey: Key.primingOffered) }

    func markPrimingOffered() {
        defaults.set(true, forKey: Key.primingOffered)
    }

    /// Notes that the user said no to the permission (declined the screen, or refused the system prompt). Only the
    /// first "no" counts: it starts the wait for the re-ask, and a later one must not postpone it.
    func recordPermissionDeclined() {
        recordFirst(Key.permissionDeclinedAt)
    }

    /// Whether the one re-ask of the permission is due: there was a "no", `reaskDelay` has passed, and it was not
    /// offered yet.
    func shouldReaskPermission() -> Bool {
        isReaskDue(declinedKey: Key.permissionDeclinedAt, shownKey: Key.permissionReaskShown)
    }

    func markPermissionReaskShown() {
        defaults.set(true, forKey: Key.permissionReaskShown)
    }

    // MARK: - Step 2/2: the campaign consent

    /// Whether the consent step has been shown on this device.
    var hasOfferedConsent: Bool { defaults.bool(forKey: Key.consentOffered) }

    func markConsentOffered() {
        defaults.set(true, forKey: Key.consentOffered)
    }

    /// Notes that the user said no to the consent (or closed the step without answering). Only the first counts.
    func recordConsentDeclined() {
        recordFirst(Key.consentDeclinedAt)
    }

    /// Whether the one re-ask of the consent is due (see `shouldReaskPermission()`).
    func shouldReaskConsent() -> Bool {
        isReaskDue(declinedKey: Key.consentDeclinedAt, shownKey: Key.consentReaskShown)
    }

    func markConsentReaskShown() {
        defaults.set(true, forKey: Key.consentReaskShown)
    }

    // MARK: - Private

    private func recordFirst(_ key: String) {
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(now().timeIntervalSince1970, forKey: key)
    }

    private func isReaskDue(declinedKey: String, shownKey: String) -> Bool {
        guard !defaults.bool(forKey: shownKey),
              let declinedAt = defaults.object(forKey: declinedKey) as? Double else { return false }
        return now().timeIntervalSince1970 - declinedAt >= Self.reaskDelay
    }
}

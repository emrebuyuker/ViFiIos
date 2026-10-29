import Foundation

/// Where a notification prompt or a consent answer comes from. Reported as the `source` analytics parameter.
nonisolated enum NotificationPromptSource: String, Sendable {
    /// The first offer: the permission flow after the onboarding tour (or its catch-up for existing users).
    case prompt
    /// A contextual second offer after an earlier "no" (after a submission, or when the inbox is opened).
    case reask
    /// Account › Bildirim Ayarları.
    case settings
}

/// Where a recorded consent was given: the consent record's `source` field, which accepts exactly these two
/// values (NOTIFICATIONS.md §6). A re-ask is a prompt too.
nonisolated enum NotificationConsentSource: String, Sendable {
    case prompt
    case settings
}

/// The user's answer to "may ViFi send you campaigns and student offers?" (Apple 4.5.4: an explicit in-app opt-in,
/// off until given, with an in-app way to withdraw it). The server filters campaigns on `marketing == true`, so
/// a user without a record sees none, in the inbox included.
nonisolated struct NotificationConsent: Equatable, Sendable {
    let marketing: Bool

    /// The version of the consent wording written with every answer, so a later wording change can tell old
    /// answers from new ones. (The rules accept 1…99.)
    static let currentVersion = 1
}

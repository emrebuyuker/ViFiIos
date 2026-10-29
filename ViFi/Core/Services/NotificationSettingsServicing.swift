import Foundation

/// Why the consent record could not be read.
nonisolated enum NotificationSettingsError: LocalizedError, Equatable, Sendable {
    case unavailable

    var errorDescription: String? {
        String(localized: "Bildirim tercihin şu an okunamıyor. Bağlantını kontrol edip tekrar dene.")
    }
}

/// One delivery of the consent record: the answer, `nil` when the user never answered, or the failure that ended
/// the stream. Kept apart from "never answered", so a failed listener never reads as a missing consent.
typealias NotificationConsentFeed = Result<NotificationConsent?, NotificationSettingsError>

/// Reads and writes the signed-in user's campaign-notification consent,
/// `users/{uid}/settings/notifications` (NOTIFICATIONS.md §3.5).
protocol NotificationSettingsServicing: AnyObject {
    /// The consent record: emits right away and again on each change, and ends when the consuming task is
    /// cancelled. A stream that fails emits one `.failure` and then ends.
    func consentChanges(uid: String) -> AsyncStream<NotificationConsentFeed>

    /// Records the answer with the wording version and a server timestamp. Throws when it is rejected (the
    /// rules accept exactly `{marketing, source, version, updatedAt}`); a write made offline is queued.
    func setMarketing(_ enabled: Bool, source: NotificationConsentSource, uid: String) async throws
}

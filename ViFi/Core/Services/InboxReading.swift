import Foundation

/// Why an inbox source could not be read. Kept apart from "nothing there", so a failed listener never shows
/// up as an empty inbox.
nonisolated enum InboxError: LocalizedError, Equatable, Sendable {
    case unavailable

    var errorDescription: String? {
        String(localized: "Bildirimler yüklenemedi. Bağlantını kontrol edip tekrar dene.")
    }
}

/// One delivery of a source: its entries (newest first), or the failure that ended the stream.
typealias InboxFeed = Result<[InboxItem], InboxError>

/// Reads what the in-app inbox shows (NOTIFICATIONS.md §3.2, §3.5): the public broadcast announcements, the
/// signed-in user's own inbox, and the marker that tells which of them were already seen.
///
/// Every stream emits right away and again on each change, and ends when the consuming task is cancelled. A
/// stream that fails emits one `.failure` and then ends.
protocol InboxReading: AnyObject {
    /// `announcements`: sent to everyone (newest 50).
    func broadcastChanges() -> AsyncStream<InboxFeed>

    /// `users/{uid}/inbox`: sent to this user — a segment, a campaign, or an automatic message (newest 100).
    func personalChanges(uid: String) -> AsyncStream<InboxFeed>

    /// `users/{uid}/settings/inbox.readAt`: when the user last opened the inbox; `nil` when the server has no
    /// marker (a new account). A `.success(nil)` must be confirmed by the server — the store writes a marker for it.
    func readMarkerChanges(uid: String) -> AsyncStream<Result<Date?, InboxError>>

    /// Records "the inbox was opened now" (a server timestamp), so every device's unread count follows.
    func markRead(uid: String) async throws
}

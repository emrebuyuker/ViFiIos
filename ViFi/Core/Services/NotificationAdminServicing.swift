import Foundation

/// Admin-only notification sending ("Bildirim Gönder"). Every call goes through an admin-gated Cloud Function
/// (NOTIFICATIONS.md §4); the server re-validates everything and is the authority on who receives what.
protocol NotificationAdminServicing: AnyObject {
    /// The audience pickers' data: only universities / faculties / departments registered users have.
    func audience() async throws -> AudienceFacets
    /// The exact reach of a notification (campaigns narrowed to users who opted in).
    func preview(kind: NotificationKind, audience: NotificationAudience) async throws -> NotificationPreview
    /// Uploads a campaign image — a JPEG of at most `NotificationImage.maxBytes` — for notification `notificationId`,
    /// to `NotificationImage.storagePath(forNotificationId:)`, and returns that path for `draft.imagePath`. Call it
    /// before `send`. The Storage rules forbid overwriting, so an image already uploaded for this id (a retried send)
    /// is kept and its path returned.
    func uploadImage(_ jpeg: Data, notificationId: String) async throws -> String
    /// Sends (or schedules) the draft. Idempotent per `draft.id`: a retry returns the first result.
    func send(_ draft: NotificationDraft) async throws -> NotificationSendResult
    /// Cancels a scheduled notification; fails with `.notCancelable` once it has gone out.
    func cancel(notificationId: String) async throws
    /// The most recent notifications, newest first (admin and automatic).
    func history() async throws -> [SentNotification]
}

/// Notification-sending failures, with Turkish messages for the admin UI.
nonisolated enum NotificationAdminError: LocalizedError, Equatable {
    case permissionDenied
    /// The server refused the draft (its message says why).
    case invalidDraft(message: String)
    /// The notification has already been sent (or canceled) and can no longer be canceled.
    case notCancelable
    /// The campaign image could not be uploaded (nothing was sent).
    case imageUploadFailed
    case offline
    /// The service is not available in this build yet.
    case unavailable
    case unknown(message: String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            String(localized: "Bu işlem için yetkin yok.")
        case let .invalidDraft(message):
            message
        case .notCancelable:
            String(localized: "Bu bildirim gönderildiği için artık iptal edilemez.")
        case .imageUploadFailed:
            String(localized: "Görsel yüklenemedi; bildirim gönderilmedi. Tekrar dene.")
        case .offline:
            String(localized: "İnternet bağlantısı yok. Bağlantını kontrol edip tekrar dene.")
        case .unavailable:
            String(localized: "Bildirim gönderme henüz kullanılamıyor.")
        case let .unknown(message):
            message
        }
    }
}

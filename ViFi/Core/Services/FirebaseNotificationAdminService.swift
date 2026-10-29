import Foundation

/// Calls the admin notification Cloud Functions (`getNotificationAudience`, `previewNotification`,
/// `sendNotification`, `cancelNotification`) and reads the `notifications` history.
///
/// Placeholder until the backend ships (NOTIFICATIONS.md phase 1, track C): every call reports `.unavailable`.
final class FirebaseNotificationAdminService: NotificationAdminServicing {
    func audience() async throws -> AudienceFacets {
        throw NotificationAdminError.unavailable
    }

    func preview(kind: NotificationKind, audience: NotificationAudience) async throws -> NotificationPreview {
        throw NotificationAdminError.unavailable
    }

    func send(_ draft: NotificationDraft) async throws -> NotificationSendResult {
        throw NotificationAdminError.unavailable
    }

    func cancel(notificationId: String) async throws {
        throw NotificationAdminError.unavailable
    }

    func history() async throws -> [SentNotification] {
        throw NotificationAdminError.unavailable
    }
}

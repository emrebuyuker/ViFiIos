import Foundation

/// What a user did with a notification that the admin history counts (NOTIFICATIONS.md §3.1 `stats.opened` /
/// `stats.actionTapped`). The raw values are the `trackNotificationEvent` callable's `event` names.
nonisolated enum NotificationEvent: String, Sendable, CaseIterable {
    /// The inbox was opened from this notification's push.
    case opened
    /// The notification's button, or its card, was used.
    case actionTapped
}

/// Tells the server that the signed-in user opened or acted on a notification, so the admin history can count it
/// (once per user and event; the server dedupes). The live implementation calls the `trackNotificationEvent` Cloud
/// Function; the no-op is used in mock mode and as the default, so nothing is sent unless the app is wired to Firebase.
protocol NotificationEventReporting: AnyObject {
    /// Reports `event` for `notificationId`. Throws when the report did not reach the server.
    func report(_ event: NotificationEvent, notificationId: String) async throws
}

/// Drops every report. Used in mock/preview/tests and as the default dependency.
final class NoopNotificationEventReporter: NotificationEventReporting {
    init() {}
    func report(_ event: NotificationEvent, notificationId: String) async throws {}
}

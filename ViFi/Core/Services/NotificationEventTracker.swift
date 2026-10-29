import Foundation
import os

/// Reports the notification events the admin history counts (`opened`, `actionTapped`), without ever getting in
/// the user's way.
///
/// Fire-and-forget: `report(_:notificationId:uid:)` returns at once and the network call runs in the background; a
/// failure is only logged. Each event for a notification is sent once per user and device — what the server
/// acknowledged is remembered in `UserDefaults`, so reopening the same push, or tapping the button again, costs no
/// request. The server dedupes per user as well, so this only saves traffic; a lost report is retried by the next
/// tap on the same notification, because only an acknowledged one is remembered.
///
/// The memory is keyed by user too: on a shared device a second account that opens the same broadcast must still be
/// counted. It keeps the newest `capacity` entries, so it cannot grow without bound.
final class NotificationEventTracker {
    /// Bump the suffix on an incompatible change: the old key is then ignored.
    static let defaultsKey = "notifications.reportedEvents.v1"
    /// How many acknowledged reports are remembered.
    static let capacity = 500

    private let reporter: any NotificationEventReporting
    private let defaults: UserDefaults
    /// Acknowledged reports, oldest first.
    private var reported: [String]
    /// Reports being sent, so a second tap before the answer does not send a second request.
    private var inFlight: Set<String> = []

    init(reporter: any NotificationEventReporting, defaults: UserDefaults = .standard) {
        self.reporter = reporter
        self.defaults = defaults
        reported = defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    /// Reports `event` for `notificationId` on behalf of `uid`, unless that was already acknowledged (or is being
    /// sent). Returns the background task, or `nil` when there was nothing to send; callers ignore it, tests await it.
    @discardableResult
    func report(_ event: NotificationEvent, notificationId: String, uid: String) -> Task<Void, Never>? {
        let key = Self.key(event, notificationId: notificationId, uid: uid)
        guard !reported.contains(key), inFlight.insert(key).inserted else { return nil }
        return Task {
            defer { inFlight.remove(key) }
            do {
                try await reporter.report(event, notificationId: notificationId)
                remember(key)
            } catch {
                let reason = String(describing: error)
                Logger.app.error(
                    "Reporting \(event.rawValue, privacy: .public) for a notification failed: \(reason, privacy: .public)"
                )
            }
        }
    }

    private func remember(_ key: String) {
        reported.append(key)
        if reported.count > Self.capacity {
            reported.removeFirst(reported.count - Self.capacity)
        }
        defaults.set(reported, forKey: Self.defaultsKey)
    }

    private static func key(_ event: NotificationEvent, notificationId: String, uid: String) -> String {
        "\(uid)|\(event.rawValue)|\(notificationId)"
    }
}

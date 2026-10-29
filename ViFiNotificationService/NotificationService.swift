import FirebaseMessaging
import Foundation
import UserNotifications

/// Runs for every push the app receives while it is not open (the server always sets `mutable-content`,
/// NOTIFICATIONS.md §5): raises the icon badge by one and attaches the campaign image when the push carries one.
///
/// - Badge: one more than the badge the app last set, shared through the App Group (`NotificationBadgeCounter`).
/// - Image: Firebase Messaging downloads `fcm_options.image` — a short-lived signed URL the server mints at
///   delivery — and attaches it. When the download fails or the system's time runs out first, the notification
///   is still shown, with its badge but without the image.
///
/// `nonisolated`: the system calls the extension on its own queues, not the main actor.
nonisolated final class NotificationService: UNNotificationServiceExtension {
    private let delivery = SingleDelivery()

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        if let counter = NotificationBadgeCounter.shared() {
            content.badge = NSNumber(value: counter.increment())
        }
        // What to show if time runs out: the text and the badge, without the image. A separate copy, because
        // Firebase keeps changing `content` (the attachment) on its download queue.
        let fallback = (content.copy() as? UNNotificationContent) ?? request.content
        delivery.start(fallback: fallback, handler: contentHandler)
        Messaging.serviceExtension().populateNotificationContent(content) { [delivery] finished in
            delivery.deliver(finished)
        }
    }

    override func serviceExtensionTimeWillExpire() {
        delivery.deliverFallback()
    }
}

/// Hands the notification to the system exactly once: the image download and the expiry deadline race for it,
/// on different queues.
private nonisolated final class SingleDelivery: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((UNNotificationContent) -> Void)?
    private var fallback: UNNotificationContent?

    func start(fallback: UNNotificationContent, handler: @escaping (UNNotificationContent) -> Void) {
        lock.withLock {
            self.fallback = fallback
            self.handler = handler
        }
    }

    func deliver(_ content: UNNotificationContent) {
        take()?.handler(content)
    }

    func deliverFallback() {
        guard let pending = take() else { return }
        pending.handler(pending.fallback)
    }

    /// The pending handler and fallback, cleared so a second call does nothing.
    private func take() -> (handler: (UNNotificationContent) -> Void, fallback: UNNotificationContent)? {
        lock.withLock {
            defer {
                handler = nil
                fallback = nil
            }
            guard let handler, let fallback else { return nil }
            return (handler, fallback)
        }
    }
}

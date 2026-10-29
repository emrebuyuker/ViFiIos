#if DEBUG
import Foundation

/// The campaign-notification consent in memory, for previews, UI tests and demos: never touches Firebase. A write
/// is kept (like the server would) and every open stream sees it, so the Account switch and the permission flow
/// agree with each other within a run.
final class StubNotificationSettingsService: NotificationSettingsServicing {
    private var consent: NotificationConsent?
    private var continuations: [AsyncStream<NotificationConsentFeed>.Continuation] = []

    /// - Parameter consent: The stored answer; `nil` for a user who never answered.
    init(consent: NotificationConsent? = nil) {
        self.consent = consent
    }

    func consentChanges(uid: String) -> AsyncStream<NotificationConsentFeed> {
        let (stream, continuation) = AsyncStream.makeStream(of: NotificationConsentFeed.self)
        continuation.yield(.success(consent))
        continuations.append(continuation)
        return stream
    }

    func setMarketing(_ enabled: Bool, source: NotificationConsentSource, uid: String) async throws {
        let stored = NotificationConsent(marketing: enabled)
        consent = stored
        for continuation in continuations {
            continuation.yield(.success(stored))
        }
    }
}
#endif

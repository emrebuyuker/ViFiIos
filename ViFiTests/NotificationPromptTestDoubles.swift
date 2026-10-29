import Foundation
@testable import ViFi

// MARK: - OS permission

/// A `NotificationServicing` with a permission the test sets, and the answers the system would give: what a
/// provisional request leads to, and what the user decides at the full-permission prompt.
final class StubNotificationService: NotificationServicing {
    var current: NotificationPermission
    /// The permission after `requestAuthorization()` (the user's choice at the system prompt).
    var permissionAfterRequest: NotificationPermission = .authorized

    private(set) var provisionalRequests = 0
    private(set) var authorizationRequests = 0

    init(_ permission: NotificationPermission = .notDetermined) {
        current = permission
    }

    func permission() async -> NotificationPermission {
        current
    }

    @discardableResult
    func requestProvisionalAuthorization() async -> Bool {
        provisionalRequests += 1
        guard current == .notDetermined else { return false }
        current = .provisional
        return true
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        current = permissionAfterRequest
        return permissionAfterRequest.deliversNotifications
    }
}

// MARK: - Consent record

/// A `NotificationSettingsServicing` the test drives by hand: the stream emits its current value when opened and
/// again whenever the test emits one; writes are recorded and, like the server, move the stored answer.
final class ScriptedNotificationSettingsService: NotificationSettingsServicing {
    struct Write: Equatable {
        let marketing: Bool
        let source: NotificationConsentSource
        let uid: String
    }

    /// What the stream answers with when it is opened; `nil` stays silent until the test emits.
    var feed: NotificationConsentFeed? = .success(nil)
    /// Fails `setMarketing` when set.
    var writeError: (any Error)?
    /// Holds `setMarketing` until the test opens it (an unreachable server).
    var writeGate: AsyncGate?

    private(set) var writes: [Write] = []
    private(set) var openedUsers: [String] = []
    private var continuations: [AsyncStream<NotificationConsentFeed>.Continuation] = []

    func consentChanges(uid: String) -> AsyncStream<NotificationConsentFeed> {
        openedUsers.append(uid)
        let (stream, continuation) = AsyncStream.makeStream(of: NotificationConsentFeed.self)
        if let feed {
            continuation.yield(feed)
        }
        continuations.append(continuation)
        return stream
    }

    func setMarketing(_ enabled: Bool, source: NotificationConsentSource, uid: String) async throws {
        writes.append(Write(marketing: enabled, source: source, uid: uid))
        if let writeGate {
            await writeGate.pass()
        }
        if let writeError {
            throw writeError
        }
        emit(.success(NotificationConsent(marketing: enabled)))
    }

    func emit(_ feed: NotificationConsentFeed) {
        self.feed = feed
        continuations.forEach { $0.yield(feed) }
    }

    func finishAll() {
        continuations.forEach { $0.finish() }
    }
}

/// A rejected write (the rules said no).
struct ConsentWriteRejected: Error {}

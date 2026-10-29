import Foundation
@testable import ViFi

// MARK: - Admin notifications

/// A `NotificationAdminServicing` that answers with scripted results and records every call.
final class StubNotificationAdminService: NotificationAdminServicing {
    var facetsResult: Result<AudienceFacets, any Error> = .success(AudienceFacets(total: 0, universities: []))
    var previewResult: Result<NotificationPreview, any Error> = .success(NotificationPreview(recipients: 0, pushTargets: 0))
    /// `nil` answers each send with a `sent` result for that draft.
    var sendResult: Result<NotificationSendResult, any Error>?
    /// When set, every image upload fails with it.
    var uploadError: (any Error)?
    var cancelError: (any Error)?
    var historyResult: Result<[SentNotification], any Error> = .success([])
    /// When set, every call waits at the gate before it is answered.
    var gate: AsyncGate?

    private(set) var previewRequests: [(kind: NotificationKind, audience: NotificationAudience)] = []
    private(set) var sentDrafts: [NotificationDraft] = []
    private(set) var canceledIDs: [String] = []
    /// Every upload attempt, in order, by notification id.
    private(set) var uploadRequests: [(notificationId: String, bytes: Int)] = []
    /// What is "in Storage": the first upload per path wins (overwriting is denied, like the rules).
    private(set) var storedImages: [String: Data] = [:]

    func uploadImage(_ jpeg: Data, notificationId: String) async throws -> String {
        uploadRequests.append((notificationId, jpeg.count))
        await gate?.pass()
        if let uploadError {
            throw uploadError
        }
        let path = NotificationImage.storagePath(forNotificationId: notificationId)
        if storedImages[path] == nil {
            storedImages[path] = jpeg
        }
        return path
    }

    func audience() async throws -> AudienceFacets {
        await gate?.pass()
        return try facetsResult.get()
    }

    func preview(kind: NotificationKind, audience: NotificationAudience) async throws -> NotificationPreview {
        previewRequests.append((kind, audience))
        await gate?.pass()
        return try previewResult.get()
    }

    func send(_ draft: NotificationDraft) async throws -> NotificationSendResult {
        sentDrafts.append(draft)
        await gate?.pass()
        if let sendResult {
            return try sendResult.get()
        }
        return NotificationSendResult(notificationId: draft.id, status: .sent, scheduledAt: nil, recipients: 0)
    }

    func cancel(notificationId: String) async throws {
        canceledIDs.append(notificationId)
        await gate?.pass()
        if let cancelError {
            throw cancelError
        }
    }

    func history() async throws -> [SentNotification] {
        await gate?.pass()
        return try historyResult.get()
    }
}

// MARK: - Device registration

/// Records device registrations; optionally fails them.
final class SpyDeviceRegistrar: DeviceRegistering {
    var registerError: (any Error)?
    var unregisterError: (any Error)?

    private(set) var registered: [(token: String, uid: String)] = []
    private(set) var unregistered: [String] = []

    func register(token: String, uid: String) async throws {
        registered.append((token, uid))
        if let registerError {
            throw registerError
        }
    }

    func unregister(uid: String) async throws {
        unregistered.append(uid)
        if let unregisterError {
            throw unregisterError
        }
    }
}

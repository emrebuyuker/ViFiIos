#if DEBUG
import Foundation

// MARK: - Admin notifications

/// Admin notification sending in memory, for previews, UI tests and demos: sample audience data, sends always
/// succeed and land in the history.
final class MockNotificationAdminService: NotificationAdminServicing {
    private(set) var sent: [SentNotification]
    /// Uploaded campaign images by storage path (kept in memory; nothing leaves the device).
    private(set) var uploadedImages: [String: Data] = [:]

    init(history: [SentNotification] = MockNotificationAdminService.sampleHistory) {
        sent = history
    }

    func uploadImage(_ jpeg: Data, notificationId: String) async throws -> String {
        let path = NotificationImage.storagePath(forNotificationId: notificationId)
        // Like the Storage rules: an image already uploaded for this id is kept, never replaced.
        if uploadedImages[path] == nil {
            uploadedImages[path] = jpeg
        }
        return path
    }

    func audience() async throws -> AudienceFacets {
        Self.sampleFacets
    }

    func preview(kind: NotificationKind, audience: NotificationAudience) async throws -> NotificationPreview {
        let reach = switch audience {
        case .all: Self.sampleFacets.total
        case let .segment(segment): Self.sampleFacets.estimatedRecipients(for: segment)
        case .user, .admins: 1
        }
        // Campaigns reach only users who opted in; about half in the sample data.
        let recipients = kind == .promo ? reach / 2 : reach
        return NotificationPreview(recipients: recipients, pushTargets: recipients)
    }

    func send(_ draft: NotificationDraft) async throws -> NotificationSendResult {
        if let existing = sent.first(where: { $0.id == draft.id }) {
            return NotificationSendResult(
                notificationId: existing.id,
                status: existing.status,
                scheduledAt: existing.scheduledAt,
                recipients: existing.stats.recipients
            )
        }
        let reach = try await preview(kind: draft.effectiveKind, audience: draft.audience)
        let recipients = draft.isTest ? 1 : reach.recipients
        let status: NotificationStatus = draft.scheduledAt == nil ? .sent : .scheduled
        sent.insert(SentNotification(
            id: draft.id,
            kind: draft.effectiveKind,
            title: draft.trimmedTitle,
            body: draft.trimmedBody,
            audience: draft.audience,
            audienceLabel: draft.isTest ? "Test (yalnız sen)" : "Örnek kitle",
            status: status,
            isTest: draft.isTest,
            isAutomatic: false,
            deferredByQuietHours: false,
            createdAt: .now,
            scheduledAt: draft.scheduledAt,
            sentAt: status == .sent ? .now : nil,
            stats: NotificationStats(
                recipients: recipients,
                pushTargets: recipients,
                pushSent: status == .sent ? recipients : 0,
                pushFailed: 0,
                opened: 0,
                actionTapped: 0
            )
        ), at: 0)
        return NotificationSendResult(
            notificationId: draft.id,
            status: status,
            scheduledAt: draft.scheduledAt,
            recipients: recipients
        )
    }

    func cancel(notificationId: String) async throws {
        guard let index = sent.firstIndex(where: { $0.id == notificationId }), sent[index].status == .scheduled else {
            throw NotificationAdminError.notCancelable
        }
        let row = sent[index]
        sent[index] = SentNotification(
            id: row.id,
            kind: row.kind,
            title: row.title,
            body: row.body,
            audience: row.audience,
            audienceLabel: row.audienceLabel,
            status: .canceled,
            isTest: row.isTest,
            isAutomatic: row.isAutomatic,
            deferredByQuietHours: row.deferredByQuietHours,
            createdAt: row.createdAt,
            scheduledAt: row.scheduledAt,
            sentAt: nil,
            stats: row.stats
        )
    }

    func history() async throws -> [SentNotification] {
        sent
    }

    // MARK: Sample data

    static let sampleFacets = AudienceFacets(total: 64, universities: [
        node("bogazici-universitesi", "Boğaziçi Üniversitesi", 40, 22, 18, children: [
            node("muhendislik-fakultesi", "Mühendislik Fakültesi", 28, 14, 14, children: [
                node("bilgisayar-muhendisligi", "Bilgisayar Mühendisliği", 17, 8, 9),
                node("endustri-muhendisligi", "Endüstri Mühendisliği", 11, 6, 5),
            ]),
            node("iktisadi-ve-idari-bilimler-fakultesi", "İktisadi ve İdari Bilimler Fakültesi", 12, 8, 4, children: [
                node("isletme", "İşletme", 12, 8, 4),
            ]),
        ]),
        node("sakarya-universitesi", "Sakarya Üniversitesi", 24, 9, 15, children: [
            node("muhendislik-fakultesi", "Mühendislik Fakültesi", 24, 9, 15, children: [
                node("makine-muhendisligi", "Makine Mühendisliği", 24, 9, 15),
            ]),
        ]),
    ])

    static let sampleHistory: [SentNotification] = [
        SentNotification(
            id: "sample-promo",
            kind: .promo,
            title: "Kampüs kafede %20 indirim",
            body: "Öğrenci kartını göster, tüm içeceklerde %20 indirim kazan.",
            audience: .segment(NotificationSegment(
                universityId: "bogazici-universitesi",
                facultyId: nil,
                departmentId: nil,
                gender: nil
            )),
            audienceLabel: "Boğaziçi Üniversitesi",
            status: .sent,
            isTest: false,
            isAutomatic: false,
            deferredByQuietHours: true,
            createdAt: Date(timeIntervalSince1970: 1_761_700_000),
            scheduledAt: Date(timeIntervalSince1970: 1_761_717_600),
            sentAt: Date(timeIntervalSince1970: 1_761_717_600),
            stats: NotificationStats(recipients: 18, pushTargets: 21, pushSent: 20, pushFailed: 1, opened: 9, actionTapped: 4)
        ),
        SentNotification(
            id: "sample-general",
            kind: .general,
            title: "Yeni sınavlar eklendi",
            body: "Bilgisayar Mühendisliği'ne 2024 vize ve finalleri eklendi.",
            audience: .all,
            audienceLabel: "Tüm kullanıcılar",
            status: .sent,
            isTest: false,
            isAutomatic: false,
            deferredByQuietHours: false,
            createdAt: Date(timeIntervalSince1970: 1_761_000_000),
            scheduledAt: nil,
            sentAt: Date(timeIntervalSince1970: 1_761_000_000),
            stats: NotificationStats(recipients: 64, pushTargets: 70, pushSent: 70, pushFailed: 0, opened: 31, actionTapped: 0)
        ),
    ]

    private static func node(
        _ id: String,
        _ name: String,
        _ total: Int,
        _ female: Int,
        _ male: Int,
        children: [AudienceNode] = []
    ) -> AudienceNode {
        AudienceNode(id: id, name: name, counts: AudienceCounts(total: total, female: female, male: male), children: children)
    }
}

// MARK: - Device registration

/// Device registration in memory: remembers the last token per user, never touches Firebase.
final class MockDeviceRegistrar: DeviceRegistering {
    private(set) var tokens: [String: String] = [:]

    func register(token: String, uid: String) async throws {
        tokens[uid] = token
    }

    func unregister(uid: String) async throws {
        tokens[uid] = nil
    }
}
#endif

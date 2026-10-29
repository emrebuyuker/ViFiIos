import Foundation

/// A notification an admin is composing ("Bildirim Gönder"). Validated here and again by the server
/// (`sendNotification`), which is the authority.
nonisolated struct NotificationDraft: Hashable, Sendable {
    static let titleLimit = 80
    static let bodyLimit = 500
    static let urlLimit = 500

    /// What the admin attaches; the exam is given by id and resolved server-side.
    enum Action: Hashable, Sendable {
        case location(NotificationLocation)
        case exam(examId: String)
        case paywall
        case addExam
        case url(URL)
    }

    /// Why a draft cannot be sent yet, with Turkish messages for the composer.
    enum Issue: Equatable, Sendable {
        case emptyTitle
        case titleTooLong
        case emptyBody
        case bodyTooLong
        case invalidAudience
        case invalidLocation
        case invalidURL
        case emptyExam
        case scheduleInPast
        case expiryBeforeDelivery

        var message: String {
            switch self {
            case .emptyTitle: String(localized: "Başlık boş olamaz.")
            case .titleTooLong: String(localized: "Başlık en fazla \(NotificationDraft.titleLimit) karakter olabilir.")
            case .emptyBody: String(localized: "Mesaj boş olamaz.")
            case .bodyTooLong: String(localized: "Mesaj en fazla \(NotificationDraft.bodyLimit) karakter olabilir.")
            case .invalidAudience: String(localized: "Geçerli bir hedef kitle seç.")
            case .invalidLocation: String(localized: "Haritadan geçerli bir konum seç.")
            case .invalidURL: String(localized: "Bağlantı https:// ile başlamalı.")
            case .emptyExam: String(localized: "Bağlanacak sınavı seç.")
            case .scheduleInPast: String(localized: "Gönderim zamanı geçmişte olamaz.")
            case .expiryBeforeDelivery: String(localized: "Geçerlilik süresi gönderim zamanından sonra olmalı.")
            }
        }
    }

    /// The server-side `notificationId`, generated once per draft so a retried send is not delivered twice.
    var id: String = UUID().uuidString.lowercased()
    var kind: NotificationKind = .general
    var title: String = ""
    var body: String = ""
    var action: Action?
    /// Storage path of an uploaded campaign image (`notificationImages/<id>.jpg`).
    var imagePath: String?
    var audience: NotificationAudience = .all
    /// `nil` sends now (subject to quiet hours for campaigns).
    var scheduledAt: Date?
    var expiresAt: Date?
    /// Sends only to the composing admin, to preview it on a real device.
    var isTest: Bool = false

    /// The kind actually sent: a location is always advertising, so it always goes as `promo` (and so only to
    /// users who opted in).
    var effectiveKind: NotificationKind {
        if case .location = action { return .promo }
        return kind
    }

    var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedBody: String { body.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The first problem that blocks sending, or `nil` when the draft is ready.
    func validationIssue(now: Date = .now) -> Issue? {
        if trimmedTitle.isEmpty { return .emptyTitle }
        if trimmedTitle.count > Self.titleLimit { return .titleTooLong }
        if trimmedBody.isEmpty { return .emptyBody }
        if trimmedBody.count > Self.bodyLimit { return .bodyTooLong }
        if !Self.isSendable(audience) { return .invalidAudience }
        if let issue = Self.issue(with: action) { return issue }
        // A minute of grace, so a time picked "now" is not rejected by the time the admin taps send.
        if let scheduledAt, scheduledAt < now.addingTimeInterval(-60) { return .scheduleInPast }
        if let expiresAt, expiresAt <= (scheduledAt ?? now) { return .expiryBeforeDelivery }
        return nil
    }

    /// The `sendNotification` callable's input (see NOTIFICATIONS.md §4). Dates are epoch milliseconds.
    var payload: [String: Any] {
        var payload: [String: Any] = [
            "notificationId": id,
            "kind": effectiveKind.rawValue,
            "title": trimmedTitle,
            "body": trimmedBody,
            "audience": Self.payload(for: audience),
            "isTest": isTest,
        ]
        if let action { payload["action"] = Self.payload(for: action) }
        if let imagePath { payload["imagePath"] = imagePath }
        if let scheduledAt { payload["scheduledAt"] = Self.milliseconds(scheduledAt) }
        if let expiresAt { payload["expiresAt"] = Self.milliseconds(expiresAt) }
        return payload
    }

    private static func isSendable(_ audience: NotificationAudience) -> Bool {
        switch audience {
        case .all:
            return true
        case let .segment(segment):
            let hasFaculty = !(segment.facultyId ?? "").isEmpty
            let hasDepartment = !(segment.departmentId ?? "").isEmpty
            return !segment.universityId.isEmpty && (hasFaculty || !hasDepartment)
        case .user, .admins:
            // Server-only audiences.
            return false
        }
    }

    private static func issue(with action: Action?) -> Issue? {
        switch action {
        case let .location(location):
            return location.isValid ? nil : .invalidLocation
        case let .exam(examId):
            return examId.trimmingCharacters(in: .whitespaces).isEmpty ? .emptyExam : nil
        case let .url(url):
            let isHTTPS = url.scheme?.lowercased() == "https" && !(url.host ?? "").isEmpty
            return isHTTPS && url.absoluteString.count <= urlLimit ? nil : .invalidURL
        case .paywall, .addExam, nil:
            return nil
        }
    }

    private static func payload(for audience: NotificationAudience) -> [String: Any] {
        var payload: [String: Any] = ["scope": audience.scope]
        switch audience {
        case let .segment(segment):
            payload["universityId"] = segment.universityId
            if let facultyId = segment.facultyId, !facultyId.isEmpty { payload["facultyId"] = facultyId }
            if let departmentId = segment.departmentId, !departmentId.isEmpty { payload["departmentId"] = departmentId }
            if let gender = segment.gender { payload["gender"] = gender.rawValue }
        case let .user(uid):
            payload["uid"] = uid
        case .all, .admins:
            break
        }
        return payload
    }

    private static func payload(for action: Action) -> [String: Any] {
        switch action {
        case let .location(location):
            var payload: [String: Any] = [
                "type": "location",
                "latitude": location.latitude,
                "longitude": location.longitude,
                "name": location.name.trimmingCharacters(in: .whitespacesAndNewlines),
            ]
            if let address = location.address, !address.isEmpty { payload["address"] = address }
            if let placeId = location.placeId, !placeId.isEmpty { payload["placeId"] = placeId }
            return payload
        case let .exam(examId):
            return ["type": "exam", "examId": examId.trimmingCharacters(in: .whitespaces)]
        case .paywall:
            return ["type": "paywall"]
        case .addExam:
            return ["type": "addExam"]
        case let .url(url):
            return ["type": "url", "url": url.absoluteString]
        }
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

/// How many registered users a node of the audience tree has, in total and per gender.
nonisolated struct AudienceCounts: Hashable, Sendable {
    let total: Int
    let female: Int
    let male: Int

    /// The users a gender filter reaches (`nil` = both, which also counts users with no gender recorded).
    func count(for gender: Gender?) -> Int {
        switch gender {
        case .female: female
        case .male: male
        case nil: total
        }
    }
}

/// A university, faculty or department that at least one registered user has in their profile.
nonisolated struct AudienceNode: Identifiable, Hashable, Sendable {
    /// The profile's canonical id (slug).
    let id: String
    let name: String
    let counts: AudienceCounts
    /// Faculties under a university, departments under a faculty; empty for a department.
    let children: [AudienceNode]
}

/// The audience pickers' data (`getNotificationAudience`): only values registered users actually have, with
/// how many users each reaches. Names and counts only — no personal data reaches the admin's device.
nonisolated struct AudienceFacets: Hashable, Sendable {
    /// Users with a completed profile.
    let total: Int
    let universities: [AudienceNode]

    func faculties(ofUniversity universityId: String) -> [AudienceNode] {
        universities.first { $0.id == universityId }?.children ?? []
    }

    func departments(ofUniversity universityId: String, faculty facultyId: String) -> [AudienceNode] {
        faculties(ofUniversity: universityId).first { $0.id == facultyId }?.children ?? []
    }

    /// The users a segment reaches according to these counts (an estimate: campaigns are further narrowed to
    /// users who opted in, which only `previewNotification` knows).
    func estimatedRecipients(for segment: NotificationSegment) -> Int {
        guard let university = universities.first(where: { $0.id == segment.universityId }) else { return 0 }
        guard let facultyId = segment.facultyId, !facultyId.isEmpty else {
            return university.counts.count(for: segment.gender)
        }
        guard let faculty = university.children.first(where: { $0.id == facultyId }) else { return 0 }
        guard let departmentId = segment.departmentId, !departmentId.isEmpty else {
            return faculty.counts.count(for: segment.gender)
        }
        return faculty.children.first { $0.id == departmentId }?.counts.count(for: segment.gender) ?? 0
    }
}

/// The exact reach of a notification before sending (`previewNotification`).
nonisolated struct NotificationPreview: Hashable, Sendable {
    /// Users who will see it in their inbox (campaigns: only those who opted in).
    let recipients: Int
    /// Registered devices a push will be sent to.
    let pushTargets: Int
}

/// Where a notification is in its delivery.
nonisolated enum NotificationStatus: String, Sendable, CaseIterable {
    case scheduled
    case sending
    case sent
    case failed
    case canceled
}

/// Delivery and engagement counters of a sent notification.
nonisolated struct NotificationStats: Hashable, Sendable {
    let recipients: Int
    let pushTargets: Int
    let pushSent: Int
    let pushFailed: Int
    let opened: Int
    let actionTapped: Int

    static let zero = NotificationStats(recipients: 0, pushTargets: 0, pushSent: 0, pushFailed: 0, opened: 0, actionTapped: 0)
}

/// The result of `sendNotification`.
nonisolated struct NotificationSendResult: Hashable, Sendable {
    let notificationId: String
    let status: NotificationStatus
    /// When it will go out, if scheduled (by the admin or deferred by quiet hours).
    let scheduledAt: Date?
    let recipients: Int
}

/// A row of the admin's notification history (`notifications/{id}`).
nonisolated struct SentNotification: Identifiable, Hashable, Sendable {
    let id: String
    let kind: NotificationKind
    let title: String
    let body: String
    let audience: NotificationAudience
    /// Human-readable audience written by the server ("Sakarya Üniversitesi › Mühendislik Fakültesi · Kadın").
    let audienceLabel: String
    let status: NotificationStatus
    let isTest: Bool
    /// Sent by an admin, or automatically (coins credited, new exam, …).
    let isAutomatic: Bool
    let deferredByQuietHours: Bool
    let createdAt: Date?
    let scheduledAt: Date?
    let sentAt: Date?
    let stats: NotificationStats
}

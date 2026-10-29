import Foundation

/// Pure parsers for the notification contract (NOTIFICATIONS.md §3–§5): Firestore documents, callable results and
/// push payloads → sendable models. Free of Firebase so they are unit-tested directly.
///
/// Dates are accepted as `Date` or as epoch milliseconds (callable results). Firestore readers convert their
/// `Timestamp` values to `Date` before calling in (see `firestoreDates(_:)` in the live readers), which keeps this
/// file free of the SDK. Unknown values are tolerated where the app can still show something useful (an unknown
/// kind reads as `.general`, an unknown action is dropped), so a newer server never blanks an older app's inbox.
nonisolated enum NotificationPayloadParser {
    // MARK: Inbox

    /// An inbox entry (`announcements/{id}` or `users/{uid}/inbox/{id}`). Requires a non-empty title.
    static func inboxItem(id: String, source: InboxItem.Source, data: [String: Any]) -> InboxItem? {
        guard isValidNotificationId(id), let title = string(data["title"]) else { return nil }
        return InboxItem(
            id: id,
            source: source,
            kind: kind(data["kind"]),
            title: title,
            body: string(data["body"]) ?? "",
            imageURL: httpsURL((data["image"] as? [String: Any])?["url"]),
            action: action(from: data["action"]),
            createdAt: date(data["createdAt"]),
            expiresAt: date(data["expiresAt"])
        )
    }

    /// A notification's action; `nil` when absent, unknown or malformed.
    static func action(from value: Any?) -> NotificationAction? {
        guard let data = value as? [String: Any], let type = string(data["type"]) else { return nil }
        switch type {
        case "location":
            return location(from: data).map(NotificationAction.location)
        case "exam":
            return examTarget(from: data).map(NotificationAction.exam)
        case "paywall":
            return .paywall
        case "addExam":
            return .addExam
        case "url":
            return httpsURL(data["url"]).map(NotificationAction.url)
        default:
            return nil
        }
    }

    static func location(from data: [String: Any]) -> NotificationLocation? {
        guard let latitude = double(data["latitude"]), let longitude = double(data["longitude"]),
              let name = string(data["name"]) else { return nil }
        let location = NotificationLocation(
            latitude: latitude,
            longitude: longitude,
            name: name,
            address: string(data["address"]),
            placeId: string(data["placeId"])
        )
        return location.isValid ? location : nil
    }

    // MARK: Admin

    /// The `getNotificationAudience` result.
    static func facets(from value: Any?) -> AudienceFacets? {
        guard let data = value as? [String: Any], let universities = data["universities"] as? [Any] else { return nil }
        return AudienceFacets(total: int(data["total"]), universities: universities.compactMap(audienceNode))
    }

    /// The `previewNotification` result.
    static func preview(from value: Any?) -> NotificationPreview? {
        guard let data = value as? [String: Any], data["recipients"] != nil else { return nil }
        return NotificationPreview(recipients: int(data["recipients"]), pushTargets: int(data["pushTargets"]))
    }

    /// The `sendNotification` result.
    static func sendResult(from value: Any?) -> NotificationSendResult? {
        guard let data = value as? [String: Any],
              let id = string(data["notificationId"]), isValidNotificationId(id),
              let status = string(data["status"]).flatMap(NotificationStatus.init(rawValue:)) else { return nil }
        return NotificationSendResult(
            notificationId: id,
            status: status,
            scheduledAt: date(data["scheduledAt"]),
            recipients: int(data["recipients"])
        )
    }

    /// A row of the admin history (`notifications/{id}`).
    static func sentNotification(id: String, data: [String: Any]) -> SentNotification? {
        guard isValidNotificationId(id), let title = string(data["title"]),
              let status = string(data["status"]).flatMap(NotificationStatus.init(rawValue:)),
              let audience = audience(from: data["audience"]) else { return nil }
        return SentNotification(
            id: id,
            kind: kind(data["kind"]),
            title: title,
            body: string(data["body"]) ?? "",
            audience: audience,
            audienceLabel: string(data["audienceLabel"]) ?? "",
            status: status,
            isTest: data["isTest"] as? Bool ?? false,
            isAutomatic: string(data["source"]) == "automatic",
            deferredByQuietHours: data["deferredByQuietHours"] as? Bool ?? false,
            createdAt: date(data["createdAt"]),
            scheduledAt: date(data["scheduledAt"]),
            sentAt: date(data["sentAt"]),
            stats: stats(from: data["stats"])
        )
    }

    static func audience(from value: Any?) -> NotificationAudience? {
        guard let data = value as? [String: Any], let scope = string(data["scope"]) else { return nil }
        switch scope {
        case "all":
            return .all
        case "segment":
            guard let universityId = string(data["universityId"]) else { return nil }
            return .segment(NotificationSegment(
                universityId: universityId,
                facultyId: string(data["facultyId"]),
                departmentId: string(data["departmentId"]),
                gender: string(data["gender"]).flatMap(Gender.init(rawValue:))
            ))
        case "user":
            return string(data["uid"]).map { .user(uid: $0) }
        case "admins":
            return .admins
        default:
            return nil
        }
    }

    // MARK: Push

    /// The notification a tapped push belongs to (`data.notificationId`), or `nil` for pushes that carry none
    /// (e.g. Firebase Auth's silent verification pushes, or a hand-made Console message).
    static func notificationId(fromPush userInfo: [AnyHashable: Any]) -> String? {
        guard let id = userInfo["notificationId"] as? String, isValidNotificationId(id) else { return nil }
        return id
    }

    /// Ids are client UUIDs or Firestore auto-ids; anything else is refused (it becomes a document id).
    static func isValidNotificationId(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
        }
    }

    // MARK: Values

    static func date(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        guard let milliseconds = double(value) else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static func kind(_ value: Any?) -> NotificationKind {
        string(value).flatMap(NotificationKind.init(rawValue:)) ?? .general
    }

    private static func examTarget(from data: [String: Any]) -> NotificationExamTarget? {
        guard let examId = string(data["examId"]),
              let ids = data["path"] as? [String], ids.count == ArchiveLevel.allCases.count, ids.last == examId,
              let kind = string(data["examKind"]).flatMap(ExamKind.init(rawValue:)) else { return nil }
        let path = ArchivePath(components: ids, displayNames: data["names"] as? [String])
        return NotificationExamTarget(examId: examId, path: path, kind: kind)
    }

    private static func audienceNode(_ value: Any) -> AudienceNode? {
        guard let data = value as? [String: Any], let id = string(data["id"]) else { return nil }
        let children = (data["faculties"] as? [Any]) ?? (data["departments"] as? [Any]) ?? []
        return AudienceNode(
            id: id,
            name: string(data["name"]) ?? id,
            counts: AudienceCounts(total: int(data["count"]), female: int(data["female"]), male: int(data["male"])),
            children: children.compactMap(audienceNode)
        )
    }

    private static func stats(from value: Any?) -> NotificationStats {
        guard let data = value as? [String: Any] else { return .zero }
        return NotificationStats(
            recipients: int(data["recipients"]),
            pushTargets: int(data["pushTargets"]),
            pushSent: int(data["pushSent"]),
            pushFailed: int(data["pushFailed"]),
            opened: int(data["opened"]),
            actionTapped: int(data["actionTapped"])
        )
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    private static func double(_ value: Any?) -> Double? {
        // Bools bridge to NSNumber too; a flag is never a coordinate or a date. (`is Bool` cannot tell them apart:
        // it is also true for an NSNumber holding 0 or 1.)
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    private static func int(_ value: Any?) -> Int {
        guard let double = double(value), double >= 0, double < Double(Int.max) else { return 0 }
        return Int(double)
    }

    private static func httpsURL(_ value: Any?) -> URL? {
        guard let text = string(value), let url = URL(string: text),
              url.scheme?.lowercased() == "https", !(url.host ?? "").isEmpty else { return nil }
        return url
    }
}

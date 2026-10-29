import Foundation

// The notification contract shared by the inbox, the admin composer and the server (see NOTIFICATIONS.md).
// Wire values (`rawValue`s, action `type`s) must stay in step with `firebase/functions/notifications/schema.js`.

/// What a notification is for. Decides who may receive it (`promo` needs the marketing opt-in, App Store 4.5.4)
/// and, on Android, the notification channel.
nonisolated enum NotificationKind: String, Codable, Sendable, CaseIterable {
    /// An announcement: maintenance, a new feature, news.
    case general
    /// A campaign or advertisement; delivered only to users who opted in to marketing notifications.
    case promo
    /// An automatic message about the user's own activity (coins credited, submission rejected, new exam).
    case system
}

/// A place attached to a campaign, opened in a maps app from the inbox.
nonisolated struct NotificationLocation: Hashable, Codable, Sendable {
    static let nameLimit = 120
    static let addressLimit = 200

    let latitude: Double
    let longitude: Double
    let name: String
    let address: String?
    /// The Google Places id, when the place was picked from a search result.
    let placeId: String?

    var isValid: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return (-90...90).contains(latitude) && (-180...180).contains(longitude)
            && !trimmedName.isEmpty && trimmedName.count <= Self.nameLimit
            && (address?.count ?? 0) <= Self.addressLimit
    }
}

/// An exam a notification links to, resolved server-side from `exams/{examId}` so the app can open it directly.
nonisolated struct NotificationExamTarget: Hashable, Sendable {
    let examId: String
    /// `[universityId, facultyId, departmentId, courseId, examId]` with their display names.
    let path: ArchivePath
    let kind: ExamKind
}

/// The single action a notification offers: its button in the inbox, and what tapping the card does.
nonisolated enum NotificationAction: Hashable, Sendable {
    case location(NotificationLocation)
    case exam(NotificationExamTarget)
    case paywall
    case addExam
    /// An external `https` link.
    case url(URL)

    /// The `type` value on the wire.
    var type: String {
        switch self {
        case .location: "location"
        case .exam: "exam"
        case .paywall: "paywall"
        case .addExam: "addExam"
        case .url: "url"
        }
    }
}

/// One entry of the in-app inbox, from either the public broadcast list or the user's own inbox.
nonisolated struct InboxItem: Identifiable, Hashable, Sendable {
    /// Where the entry was delivered.
    enum Source: String, Sendable {
        /// `announcements/{id}`: sent to everyone.
        case broadcast
        /// `users/{uid}/inbox/{id}`: sent to this user (a segment, a campaign, or an automatic message).
        case personal
    }

    /// The `notificationId`, the same in both sources (used for highlighting and statistics).
    let id: String
    let source: Source
    let kind: NotificationKind
    let title: String
    let body: String
    let imageURL: URL?
    let action: NotificationAction?
    let createdAt: Date?
    let expiresAt: Date?

    /// Whether the entry is past its validity and should no longer be shown.
    func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

/// A slice of the registered users, matched against their profile's canonical ids.
nonisolated struct NotificationSegment: Hashable, Sendable {
    let universityId: String
    /// Narrows to one faculty of the university.
    let facultyId: String?
    /// Narrows to one department of the faculty; requires `facultyId`.
    let departmentId: String?
    /// `nil` sends to both.
    let gender: Gender?
}

/// Who a notification goes to.
nonisolated enum NotificationAudience: Hashable, Sendable {
    /// Every user (and every installed app subscribed to the broadcast topic).
    case all
    case segment(NotificationSegment)
    /// One user; automatic notifications only (the admin composer cannot send it).
    case user(uid: String)
    /// Every admin; automatic notifications only.
    case admins

    /// The `scope` value on the wire.
    var scope: String {
        switch self {
        case .all: "all"
        case .segment: "segment"
        case .user: "user"
        case .admins: "admins"
        }
    }
}

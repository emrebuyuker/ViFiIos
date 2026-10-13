import Foundation

/// A notification shown in the in-app inbox. In v1 announcements are public (the same list for everyone),
/// written server-side / from the Firebase Console; read state is tracked per device (`AnnouncementsStore`).
nonisolated struct Announcement: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let body: String
    let createdAt: Date?
}

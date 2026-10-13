import Foundation

/// Reads the public announcements shown in the in-app inbox.
protocol AnnouncementsReading: AnyObject {
    /// Emits the announcements (newest first) and again whenever they change.
    func announcementsChanges() -> AsyncStream<[Announcement]>
}

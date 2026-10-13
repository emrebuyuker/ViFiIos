import Foundation
import Observation

/// The in-app inbox: the public announcements, kept live, plus the per-device read state (so the unread badge
/// reflects what this device has opened). Announcements are the same for everyone (v1); read state is local.
@Observable
final class AnnouncementsStore {
    // Bump the suffix on an incompatible change: the old key is then ignored.
    private static let readIdsKey = "announcements.readIds.v1"

    private(set) var announcements: [Announcement] = []
    private(set) var readIds: Set<String> = []

    /// How many current announcements this device has not opened yet.
    var unreadCount: Int {
        announcements.reduce(0) { $0 + (readIds.contains($1.id) ? 0 : 1) }
    }

    @ObservationIgnored private let reader: any AnnouncementsReading
    @ObservationIgnored private let defaults: UserDefaults

    init(reader: any AnnouncementsReading, defaults: UserDefaults = .standard) {
        self.reader = reader
        self.defaults = defaults
        readIds = Set(defaults.stringArray(forKey: Self.readIdsKey) ?? [])
    }

    /// Keeps the list in step with the server for as long as the task runs (cancelled on sign-out).
    func observe() async {
        for await items in reader.announcementsChanges() {
            announcements = items
        }
    }

    /// Marks every current announcement as read (called when the inbox is opened).
    func markAllRead() {
        let current = Set(announcements.map(\.id))
        guard !current.isSubset(of: readIds) else { return }
        readIds.formUnion(current)
        // Keep only ids that still exist, so the stored set stays bounded as announcements rotate out.
        readIds.formIntersection(current)
        defaults.set(Array(readIds), forKey: Self.readIdsKey)
    }

    func reset() {
        announcements = []
    }
}

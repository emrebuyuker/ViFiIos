import Foundation
import Testing
@testable import ViFi

@Suite("AnnouncementsStore")
final class AnnouncementsStoreTests {
    private let storage: TemporaryDefaults

    init() throws {
        storage = try TemporaryDefaults()
    }

    @Test("Observing loads the announcements, all unread at first")
    func observeLoadsUnread() async {
        let store = makeStore([sample("1"), sample("2")])

        await store.observe()

        #expect(store.announcements.map(\.id) == ["1", "2"])
        #expect(store.unreadCount == 2)
    }

    @Test("Marking all read clears the unread count and persists across launches")
    func markAllReadPersists() async {
        let store = makeStore([sample("1"), sample("2")])
        await store.observe()

        store.markAllRead()

        #expect(store.unreadCount == 0)
        // A new store on the same defaults, seeing the same announcements, starts fully read.
        let relaunched = makeStore([sample("1"), sample("2")])
        await relaunched.observe()
        #expect(relaunched.unreadCount == 0)
    }

    @Test("A newly arrived announcement is unread even after older ones were read")
    func newAnnouncementIsUnread() async {
        let store = makeStore([sample("1")])
        await store.observe()
        store.markAllRead()

        let withNew = makeStore([sample("1"), sample("2")])
        await withNew.observe()

        #expect(withNew.unreadCount == 1)
    }

    @Test("Reset clears the in-memory list")
    func resetClears() async {
        let store = makeStore([sample("1")])
        await store.observe()

        store.reset()

        #expect(store.announcements.isEmpty)
    }

    // MARK: - Helpers

    private func makeStore(_ announcements: [Announcement]) -> AnnouncementsStore {
        AnnouncementsStore(reader: StubAnnouncementsReader(announcements: announcements), defaults: storage.defaults)
    }

    private func sample(_ id: String) -> Announcement {
        Announcement(id: id, title: "Başlık \(id)", body: "Metin", createdAt: nil)
    }
}

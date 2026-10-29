import Foundation
import Testing
@testable import ViFi

@Suite("InboxStore", .timeLimit(.minutes(1)))
final class InboxStoreTests {
    private static let uid = "user-1"
    private static let legacyKey = "announcements.readIds.v1"

    private let storage: TemporaryDefaults
    private let reader = ScriptedInboxReader()
    private let clock = TestClock(InboxFixture.date(1_000))
    private let store: InboxStore
    private var observation: Task<Void, Never>?

    init() throws {
        storage = try TemporaryDefaults()
        store = InboxStore(reader: reader, defaults: storage.defaults, now: clock.now)
    }

    deinit {
        observation?.cancel()
    }

    // MARK: - Loading

    @Test("Until both sources answered the inbox is loading")
    func loadingUntilBothAnswer() async {
        reader.broadcast = .success([InboxFixture.item("a1")])
        reader.personal = nil

        await startObserving()

        #expect(await eventually { reader.personalUsers == [Self.uid] })
        #expect(store.state == .loading)

        reader.emitPersonal(.success([]))
        #expect(await eventually { store.state == .loaded(store.items) })
        #expect(store.items.map(\.id) == ["a1"])
    }

    @Test("Both sources are merged, newest first, and an entry both delivered is listed once")
    func mergesAndSorts() async {
        reader.broadcast = .success([
            InboxFixture.item("old", createdAt: InboxFixture.date(10)),
            InboxFixture.item("both", source: .broadcast, createdAt: InboxFixture.date(30)),
        ])
        reader.personal = .success([
            InboxFixture.item("new", source: .personal, createdAt: InboxFixture.date(50)),
            InboxFixture.item("both", source: .personal, createdAt: InboxFixture.date(30)),
            InboxFixture.item("undated", source: .personal, createdAt: nil),
        ])

        await startObservingUntilLoaded()

        #expect(store.items.map(\.id) == ["new", "both", "old", "undated"])
        #expect(store.items.first { $0.id == "both" }?.source == .personal)
    }

    @Test("Entries past their expiry are hidden, also once the clock passes it while the inbox is open")
    func hidesExpired() async {
        reader.broadcast = .success([
            InboxFixture.item("valid", expiresAt: InboxFixture.date(2_000)),
            InboxFixture.item("expired", expiresAt: InboxFixture.date(500)),
            InboxFixture.item("forever"),
        ])

        await startObservingUntilLoaded()
        #expect(Set(store.items.map(\.id)) == ["valid", "forever"])

        clock.advance(by: 1_500)
        #expect(Set(store.items.map(\.id)) == ["forever"])
    }

    @Test("An empty inbox is loaded and empty, not failed")
    func emptyIsNotFailed() async {
        await startObservingUntilLoaded()

        #expect(store.state == .loaded([]))
        #expect(!store.hasPartialFailure)
    }

    // MARK: - Failures

    @Test("When both sources fail the inbox is failed, never empty")
    func bothFail() async {
        reader.broadcast = .failure(.unavailable)
        reader.personal = .failure(.unavailable)

        await startObserving()

        #expect(await eventually { store.state == .failed(message: InboxError.unavailable.userMessage) })
    }

    @Test("When one source fails the other's entries stay and the failure is flagged")
    func oneFails() async {
        reader.broadcast = .success([InboxFixture.item("a1")])
        reader.personal = .failure(.unavailable)

        await startObservingUntilLoaded()

        #expect(store.items.map(\.id) == ["a1"])
        #expect(store.hasPartialFailure)
    }

    @Test("A source that fails later is flagged too, and one that recovers clears the flag")
    func failsAndRecovers() async {
        await startObservingUntilLoaded()

        reader.emitPersonal(.failure(.unavailable))
        #expect(await eventually { store.hasPartialFailure })

        reader.emitPersonal(.success([]))
        #expect(await eventually { !store.hasPartialFailure })
    }

    @Test("Retrying bumps the token the observing task is keyed on")
    func retryBumpsToken() {
        let before = store.retryToken

        store.retry()

        #expect(store.retryToken == before + 1)
    }

    @Test("Observing again after a retry starts over from loading")
    func reobservingRestarts() async {
        reader.broadcast = .failure(.unavailable)
        reader.personal = .failure(.unavailable)
        await startObserving()
        #expect(await eventually { store.state == .failed(message: InboxError.unavailable.userMessage) })

        stopObserving()
        reader.broadcast = .success([InboxFixture.item("a1")])
        reader.personal = .success([])
        await startObserving()

        #expect(await eventually { reader.broadcastOpenings == 2 })
        #expect(await eventually { store.state == .loaded(store.items) })
        #expect(store.items.map(\.id) == ["a1"])
    }

    // MARK: - Unread

    @Test("Nothing is unread until the read marker arrives")
    func noUnreadWithoutMarker() async {
        reader.broadcast = .success([InboxFixture.item("a1")])
        reader.readMarker = nil

        await startObservingUntilLoaded()

        #expect(store.unreadCount == 0)
    }

    @Test("An existing marker older than the entries leaves them unread, and nothing is written")
    func entriesNewerThanMarkerAreUnread() async {
        reader.broadcast = .success([
            InboxFixture.item("a1"),
            InboxFixture.item("a2", createdAt: InboxFixture.date(5)),
            InboxFixture.item("undated", createdAt: nil),
        ])

        await startObservingUntilMarkerKnown()

        #expect(store.unreadCount == 2)
        #expect(store.isUnread(InboxFixture.item("a1")))
        #expect(!store.isUnread(InboxFixture.item("undated", createdAt: nil)))
        #expect(reader.markReadCalls.isEmpty)
    }

    @Test("Unread means newer than readAt: the same instant counts as read")
    func unreadIsNewerThanReadAt() async {
        reader.broadcast = .success([
            InboxFixture.item("before", createdAt: InboxFixture.date(10)),
            InboxFixture.item("at", createdAt: InboxFixture.date(20)),
            InboxFixture.item("after", createdAt: InboxFixture.date(30)),
        ])
        reader.readMarker = .success(InboxFixture.date(20))

        await startObservingUntilMarkerKnown()

        #expect(store.items.filter(store.isUnread).map(\.id) == ["after"])
        #expect(store.unreadCount == 1)
    }

    @Test("Personal entries count as unread too")
    func personalCounts() async {
        reader.broadcast = .success([InboxFixture.item("a1", createdAt: InboxFixture.date(10))])
        reader.personal = .success([InboxFixture.item("p1", source: .personal, createdAt: InboxFixture.date(40))])
        reader.readMarker = .success(InboxFixture.date(20))

        await startObservingUntilMarkerKnown()

        #expect(store.unreadCount == 1)
    }

    @Test("An unreadable marker shows nothing as unread, rather than a badge that never clears")
    func unavailableMarker() async {
        reader.broadcast = .success([InboxFixture.item("a1")])
        reader.readMarker = .failure(.unavailable)

        await startObservingUntilLoaded()
        #expect(await eventually { store.unreadCount == 0 })

        store.markAllRead()
        #expect(reader.markReadCalls.isEmpty)
    }

    @Test("A marker written elsewhere updates the count live")
    func markerFollowsOtherDevices() async {
        reader.broadcast = .success([InboxFixture.item("a1", createdAt: InboxFixture.date(10))])
        await startObservingUntilMarkerKnown()
        #expect(store.unreadCount == 1)

        reader.emitReadMarker(.success(InboxFixture.date(50)))

        #expect(await eventually { store.unreadCount == 0 })
    }

    // MARK: - Marking read

    @Test("Marking read writes the marker once, and the count follows it")
    func marksReadOnce() async {
        reader.broadcast = .success([InboxFixture.item("a1", createdAt: InboxFixture.date(10))])
        reader.serverNow = { InboxFixture.date(100) }
        await startObservingUntilMarkerKnown()

        store.markAllRead()
        store.markAllRead()

        #expect(await eventually { store.unreadCount == 0 })
        #expect(reader.markReadCalls == [Self.uid])
    }

    @Test("Nothing unread means no write")
    func nothingToMark() async {
        reader.broadcast = .success([InboxFixture.item("a1", createdAt: InboxFixture.date(10))])
        reader.readMarker = .success(InboxFixture.date(20))
        await startObservingUntilMarkerKnown()

        store.markAllRead()

        #expect(reader.markReadCalls.isEmpty)
    }

    @Test("Something newer that arrives afterwards is written for again")
    func marksNewArrivals() async {
        reader.broadcast = .success([InboxFixture.item("a1", createdAt: InboxFixture.date(10))])
        reader.serverNow = { InboxFixture.date(100) }
        await startObservingUntilMarkerKnown()
        store.markAllRead()
        #expect(await eventually { store.unreadCount == 0 })

        reader.emitPersonal(.success([InboxFixture.item("p1", source: .personal, createdAt: InboxFixture.date(150))]))
        #expect(await eventually { store.unreadCount == 1 })
        store.markAllRead()

        #expect(await eventually { reader.markReadCalls.count == 2 })
    }

    @Test("A failed write is tried again at the next opening")
    func failedWriteRetries() async {
        reader.broadcast = .success([InboxFixture.item("a1", createdAt: InboxFixture.date(10))])
        reader.markReadError = InboxError.unavailable
        await startObservingUntilMarkerKnown()

        store.markAllRead()
        #expect(await eventually { reader.markReadCalls.count == 1 })
        // Let the failed write settle, so the retry guard is cleared.
        try? await Task.sleep(for: .milliseconds(50))

        reader.markReadError = nil
        reader.serverNow = { InboxFixture.date(100) }
        store.markAllRead()

        #expect(await eventually { reader.markReadCalls.count == 2 })
        #expect(await eventually { store.unreadCount == 0 })
    }

    // MARK: - Helpers

    private func startObserving() async {
        observation = Task { await store.observe(uid: Self.uid) }
    }

    private func stopObserving() {
        observation?.cancel()
        observation = nil
    }

    private func startObservingUntilLoaded() async {
        await startObserving()
        #expect(await eventually { store.state != .loading })
    }

    private func startObservingUntilMarkerKnown() async {
        await startObservingUntilLoaded()
        // The marker arrives on its own stream; give it the same chance as the sources.
        #expect(await eventually { markerIsKnown })
    }

    /// Whether a read marker was delivered: an entry far in the future is unread under any marker, and counts
    /// as read before one arrives.
    private var markerIsKnown: Bool {
        store.isUnread(InboxFixture.item("probe", createdAt: InboxFixture.date(1_000_000)))
    }
}

// The read-marker scenarios live in an extension (same file, so the suite's private state stays reachable), which
// keeps the suite's own body within the lint limit.
extension InboxStoreTests {
    // MARK: - New account

    @Test("A new account's existing announcements are listed but not unread, and the marker is written once")
    func newAccountStartsRead() async {
        reader.broadcast = .success([
            InboxFixture.item("old1", createdAt: InboxFixture.date(10)),
            InboxFixture.item("old2", createdAt: InboxFixture.date(500)),
        ])
        reader.readMarker = .success(nil)
        reader.serverNow = { InboxFixture.date(1_000) }

        await startObservingUntilMarkerKnown()

        #expect(await eventually { reader.markReadCalls == [Self.uid] })
        #expect(store.items.map(\.id) == ["old2", "old1"], "They still show in the list")
        #expect(store.unreadCount == 0, "...but do not light the bell")
        #expect(store.items.allSatisfy { !store.isUnread($0) })
        // The server's echo of the marker does not write again.
        #expect(await eventually { store.unreadCount == 0 })
        #expect(reader.markReadCalls == [Self.uid])
    }

    @Test("After a new account's marker is set, only later entries count as unread")
    func newAccountLaterEntriesAreUnread() async {
        reader.broadcast = .success([InboxFixture.item("old", createdAt: InboxFixture.date(10))])
        reader.readMarker = .success(nil)
        reader.serverNow = { InboxFixture.date(1_000) }
        await startObservingUntilMarkerKnown()
        #expect(await eventually { reader.markReadCalls == [Self.uid] })

        reader.emitPersonal(.success([InboxFixture.item("fresh", source: .personal, createdAt: InboxFixture.date(1_500))]))

        #expect(await eventually { store.unreadCount == 1 })
        #expect(store.items.filter(store.isUnread).map(\.id) == ["fresh"])
    }

    @Test("A repeated empty marker while the first write is on its way writes nothing more and does not flash unread")
    func newAccountWritesOnce() async {
        reader.broadcast = .success([InboxFixture.item("old", createdAt: InboxFixture.date(10))])
        reader.readMarker = .success(nil)
        reader.markReadError = InboxError.unavailable
        await startObservingUntilMarkerKnown()
        #expect(await eventually { reader.markReadCalls.count == 1 })

        reader.emitReadMarker(.success(nil))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(reader.markReadCalls.count == 1)
        #expect(store.unreadCount == 0)
    }

    @Test("A marker that cannot be read is not an empty one: nothing is written")
    func readErrorNeverWrites() async {
        reader.broadcast = .success([InboxFixture.item("a1", createdAt: InboxFixture.date(10))])
        reader.readMarker = .failure(.unavailable)

        await startObservingUntilLoaded()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(reader.markReadCalls.isEmpty)
        #expect(store.unreadCount == 0)
    }

    @Test("A marker that has not arrived yet is not an empty one: nothing is written")
    func pendingMarkerNeverWrites() async {
        reader.broadcast = .success([InboxFixture.item("a1", createdAt: InboxFixture.date(10))])
        reader.readMarker = nil

        await startObservingUntilLoaded()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(reader.markReadCalls.isEmpty)
    }

    @Test("Signing in as another new account writes that account's marker too")
    func nextNewAccountWritesItsOwn() async {
        reader.readMarker = .success(nil)
        reader.serverNow = { InboxFixture.date(1_000) }
        await startObservingUntilMarkerKnown()
        #expect(await eventually { reader.markReadCalls == [Self.uid] })

        stopObserving()
        store.reset()
        // The first write moved the scripted server's marker; the next account has none.
        reader.emitReadMarker(.success(nil))
        observation = Task { await store.observe(uid: "user-2") }

        #expect(await eventually { reader.markReadCalls == [Self.uid, "user-2"] })
    }

    // MARK: - Legacy read state

    @Test("A device that tracked read announcements locally writes readAt once and drops the old ids")
    func migratesLegacyState() async {
        storage.defaults.set(["a1"], forKey: Self.legacyKey)
        reader.readMarker = .success(nil)
        reader.broadcast = .success([InboxFixture.item("a1", createdAt: InboxFixture.date(10))])
        reader.serverNow = { InboxFixture.date(100) }

        await startObservingUntilLoaded()

        #expect(await eventually { reader.markReadCalls == [Self.uid] })
        #expect(await eventually { storage.defaults.stringArray(forKey: Self.legacyKey) == nil })
        #expect(store.unreadCount == 0, "The old announcements must not burst back as unread")
    }

    @Test("An existing readAt wins over legacy state: no migration write")
    func existingMarkerSkipsMigration() async {
        storage.defaults.set(["a1"], forKey: Self.legacyKey)
        reader.broadcast = .success([InboxFixture.item("a1", createdAt: InboxFixture.date(10))])
        reader.readMarker = .success(InboxFixture.date(5))

        await startObservingUntilMarkerKnown()

        #expect(reader.markReadCalls.isEmpty)
        #expect(store.unreadCount == 1)
    }

    @Test("A failed migration write keeps the legacy ids for the next launch")
    func failedMigrationKeepsLegacyState() async {
        storage.defaults.set(["a1"], forKey: Self.legacyKey)
        reader.readMarker = .success(nil)
        reader.markReadError = InboxError.unavailable

        await startObservingUntilMarkerKnown()

        #expect(await eventually { reader.markReadCalls.count == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(storage.defaults.stringArray(forKey: Self.legacyKey) == ["a1"])
    }

    // MARK: - Reset

    @Test("Reset forgets everything, and a stale delivery for the old user is ignored")
    func resetForgets() async {
        reader.broadcast = .success([InboxFixture.item("a1")])
        await startObservingUntilMarkerKnown()
        #expect(store.unreadCount == 1)

        store.reset()
        reader.emitBroadcast(.success([InboxFixture.item("late")]))
        try? await Task.sleep(for: .milliseconds(30))

        #expect(store.items.isEmpty)
        #expect(store.unreadCount == 0)
        #expect(store.state == .loading)
    }
}

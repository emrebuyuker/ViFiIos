import Foundation
import Observation
import os

/// The in-app inbox (NOTIFICATIONS.md §3, §3.5): the public broadcast announcements and the signed-in user's
/// own notifications, merged newest first, with the unread count behind the bell and the app icon badge.
///
/// Two live sources feed it — `announcements` (everyone) and `users/{uid}/inbox` (this user) — plus the read
/// marker `users/{uid}/settings/inbox.readAt`. An entry is unread when it is newer than `readAt`, so the count
/// is the same on every device and opening the inbox costs a single write. A source that fails is not shown as
/// empty: when both fail the inbox reports `.failed` (with a retry), when only one does the other's entries stay
/// visible and `hasPartialFailure` says some are missing. Entries past their `expiresAt` are hidden.
@Observable
final class InboxStore {
    /// What a source delivered so far.
    private enum SourceState {
        case pending
        case ready([InboxItem])
        case failed

        init(_ feed: InboxFeed) {
            switch feed {
            case let .success(items): self = .ready(items)
            case .failure: self = .failed
            }
        }

        var items: [InboxItem] {
            if case let .ready(items) = self { items } else { [] }
        }

        var isFailed: Bool {
            if case .failed = self { true } else { false }
        }

        var isPending: Bool {
            if case .pending = self { true } else { false }
        }
    }

    /// What is known about when the user last opened the inbox.
    private enum ReadMarker {
        /// Not delivered yet: nothing counts as unread until it is.
        case unknown
        /// Could not be read: nothing counts as unread, rather than a badge that never clears.
        case unavailable
        /// `nil`: the inbox was never opened.
        case known(Date?)
    }

    // The per-device set of read announcement ids the app used before the shared read marker. Bump the suffix on
    // an incompatible change: the old key is then ignored.
    private static let legacyReadIdsKey = "announcements.readIds.v1"

    private var broadcast: SourceState = .pending
    private var personal: SourceState = .pending
    private var readMarker: ReadMarker = .unknown
    /// Bumped by `retry()`. The view runs `observe(uid:)` as a task keyed on it, so a retry restarts every
    /// listener from scratch.
    private(set) var retryToken = 0

    @ObservationIgnored private let reader: any InboxReading
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var userId: String?
    /// The newest entry the last `readAt` write covered, so the same entries are not written for twice.
    @ObservationIgnored private var markedThrough: Date?
    @ObservationIgnored private var didMigrateLegacyState = false

    /// - Parameters:
    ///   - defaults: Where the pre-`readAt` read state lives (migrated on first use, see `observe(uid:)`).
    ///   - now: The clock expiry is measured with (injected by tests).
    init(reader: any InboxReading, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.reader = reader
        self.defaults = defaults
        self.now = now
    }

    // MARK: - Reading

    /// Both sources' entries, newest first, without the ones past their validity. An entry delivered by both
    /// sources is listed once, as the user's own.
    var items: [InboxItem] {
        let current = now()
        var byId: [String: InboxItem] = [:]
        for item in broadcast.items + personal.items {
            byId[item.id] = item
        }
        return byId.values
            .filter { !$0.isExpired(at: current) }
            .sorted(by: Self.isNewer)
    }

    /// `.loading` until both sources answered, `.failed` when neither could be read, otherwise the entries.
    var state: Loadable<[InboxItem]> {
        if broadcast.isFailed, personal.isFailed {
            return .failed(message: InboxError.unavailable.userMessage)
        }
        if broadcast.isPending || personal.isPending {
            return .loading
        }
        return .loaded(items)
    }

    /// One source could not be read: the entries shown may be incomplete.
    var hasPartialFailure: Bool {
        broadcast.isFailed != personal.isFailed
    }

    /// Whether `item` arrived after the user last opened the inbox.
    func isUnread(_ item: InboxItem) -> Bool {
        guard case let .known(readAt) = readMarker, let createdAt = item.createdAt else { return false }
        guard let readAt else { return true }
        return createdAt > readAt
    }

    /// How many entries the user has not seen yet (the bell's dot and the app icon badge).
    var unreadCount: Int {
        items.count(where: isUnread)
    }

    // MARK: - Observing

    /// Keeps the inbox in step with the server for `uid` until the calling task is cancelled (sign-out, or a
    /// `retry()`). The first read marker without a `readAt` also migrates the legacy per-device read state.
    func observe(uid: String) async {
        userId = uid
        broadcast = .pending
        personal = .pending
        readMarker = .unknown
        markedThrough = nil
        didMigrateLegacyState = false

        async let broadcastFollowed: Void = followBroadcast(uid: uid)
        async let personalFollowed: Void = followPersonal(uid: uid)
        async let markerFollowed: Void = followReadMarker(uid: uid)
        _ = await (broadcastFollowed, personalFollowed, markerFollowed)
    }

    /// Starts reading again after a failure (the error view's retry).
    func retry() {
        retryToken += 1
    }

    // MARK: - Marking read

    /// Records that the user has seen everything that is there now. Called while the inbox is on screen; the
    /// write happens once for what is unread and again only when something newer arrives.
    func markAllRead() {
        guard let userId, case .known = readMarker,
              let newest = items.filter(isUnread).compactMap(\.createdAt).max() else { return }
        if let markedThrough, newest <= markedThrough { return }
        markedThrough = newest
        Task {
            do {
                try await reader.markRead(uid: userId)
            } catch {
                let reason = String(describing: error)
                Logger.app.error("Marking the inbox read failed: \(reason, privacy: .public)")
                // Let the next opening (or arrival) try again.
                if markedThrough == newest {
                    markedThrough = nil
                }
            }
        }
    }

    /// Forgets everything (sign-out), so the next user starts clean.
    func reset() {
        userId = nil
        broadcast = .pending
        personal = .pending
        readMarker = .unknown
        markedThrough = nil
        didMigrateLegacyState = false
    }

    // MARK: - Private

    private func followBroadcast(uid: String) async {
        for await feed in reader.broadcastChanges() {
            guard userId == uid else { return }
            broadcast = SourceState(feed)
        }
    }

    private func followPersonal(uid: String) async {
        for await feed in reader.personalChanges(uid: uid) {
            guard userId == uid else { return }
            personal = SourceState(feed)
        }
    }

    private func followReadMarker(uid: String) async {
        for await result in reader.readMarkerChanges(uid: uid) {
            guard userId == uid else { return }
            switch result {
            case let .success(readAt):
                readMarker = .known(readAt)
                if readAt == nil {
                    migrateLegacyReadState(uid: uid)
                }
            case .failure:
                readMarker = .unavailable
            }
        }
    }

    /// First run with the shared read marker (NOTIFICATIONS.md §3.5): a device that tracked read announcements
    /// locally sets `readAt` to now, so the old ones do not all show up unread at once. Without any, everything
    /// really is unread. The local ids are dropped once the marker is written.
    private func migrateLegacyReadState(uid: String) {
        guard !didMigrateLegacyState else { return }
        didMigrateLegacyState = true
        guard !(defaults.stringArray(forKey: Self.legacyReadIdsKey) ?? []).isEmpty else { return }
        // Until the write is reflected back, count as read from now on instead of flashing everything unread.
        readMarker = .known(now())
        Task {
            do {
                try await reader.markRead(uid: uid)
                defaults.removeObject(forKey: Self.legacyReadIdsKey)
            } catch {
                let reason = String(describing: error)
                Logger.app.error("Migrating the legacy read state failed: \(reason, privacy: .public)")
            }
        }
    }

    /// Newest first; entries without a date go last, in a stable order.
    private static func isNewer(_ lhs: InboxItem, _ rhs: InboxItem) -> Bool {
        switch (lhs.createdAt, rhs.createdAt) {
        case let (left?, right?) where left != right: left > right
        case (.some, nil): true
        case (nil, .some): false
        default: lhs.id < rhs.id
        }
    }
}

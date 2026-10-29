import Foundation
@testable import ViFi

// MARK: - Inbox reading

/// An `InboxReading` the test drives by hand: each stream emits its current value when it is opened and again
/// whenever the test emits one, and stays open until the observing task is cancelled (or `finishAll()`).
final class ScriptedInboxReader: InboxReading {
    /// What each source answers with when it is opened; `nil` stays silent until the test emits.
    var broadcast: InboxFeed? = .success([])
    var personal: InboxFeed? = .success([])
    var readMarker: Result<Date?, InboxError>? = .success(nil)
    /// Fails `markRead` when set.
    var markReadError: (any Error)?
    /// The marker a successful `markRead` moves to (the server's clock).
    var serverNow: () -> Date = Date.init

    private(set) var markReadCalls: [String] = []
    private(set) var personalUsers: [String] = []
    private(set) var broadcastOpenings = 0

    private var broadcastContinuations: [AsyncStream<InboxFeed>.Continuation] = []
    private var personalContinuations: [AsyncStream<InboxFeed>.Continuation] = []
    private var markerContinuations: [AsyncStream<Result<Date?, InboxError>>.Continuation] = []

    func broadcastChanges() -> AsyncStream<InboxFeed> {
        broadcastOpenings += 1
        return Self.stream(initial: broadcast, keeping: &broadcastContinuations)
    }

    func personalChanges(uid: String) -> AsyncStream<InboxFeed> {
        personalUsers.append(uid)
        return Self.stream(initial: personal, keeping: &personalContinuations)
    }

    func readMarkerChanges(uid: String) -> AsyncStream<Result<Date?, InboxError>> {
        Self.stream(initial: readMarker, keeping: &markerContinuations)
    }

    func markRead(uid: String) async throws {
        markReadCalls.append(uid)
        if let markReadError {
            throw markReadError
        }
        emitReadMarker(.success(serverNow()))
    }

    // MARK: Driving

    func emitBroadcast(_ feed: InboxFeed) {
        broadcast = feed
        broadcastContinuations.forEach { $0.yield(feed) }
    }

    func emitPersonal(_ feed: InboxFeed) {
        personal = feed
        personalContinuations.forEach { $0.yield(feed) }
    }

    func emitReadMarker(_ result: Result<Date?, InboxError>) {
        readMarker = result
        markerContinuations.forEach { $0.yield(result) }
    }

    /// Ends every open stream, so an `observe(uid:)` that is waiting on them returns.
    func finishAll() {
        broadcastContinuations.forEach { $0.finish() }
        personalContinuations.forEach { $0.finish() }
        markerContinuations.forEach { $0.finish() }
    }

    private static func stream<Value: Sendable>(
        initial: Value?,
        keeping continuations: inout [AsyncStream<Value>.Continuation]
    ) -> AsyncStream<Value> {
        let (stream, continuation) = AsyncStream.makeStream(of: Value.self)
        if let initial {
            continuation.yield(initial)
        }
        continuations.append(continuation)
        return stream
    }
}

// MARK: - Samples

/// Builds inbox entries for the tests.
enum InboxFixture {
    static func item(
        _ id: String,
        source: InboxItem.Source = .broadcast,
        kind: NotificationKind = .general,
        createdAt: Date? = Date(timeIntervalSince1970: 1_700_000_000),
        expiresAt: Date? = nil,
        action: NotificationAction? = nil,
        imageStoragePath: String? = nil
    ) -> InboxItem {
        InboxItem(
            id: id,
            source: source,
            kind: kind,
            title: "Başlık \(id)",
            body: "Metin",
            imageStoragePath: imageStoragePath,
            action: action,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
    }

    /// `seconds` after a fixed reference date.
    static func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    }
}

// MARK: - Device registration

/// A `DeviceRegistering` whose removal never finishes until the test opens the gate (an unreachable server).
final class HangingDeviceRegistrar: DeviceRegistering {
    let gate = AsyncGate()

    func register(token: String, uid: String) async throws {}

    func unregister(uid: String) async throws {
        await gate.pass()
    }
}

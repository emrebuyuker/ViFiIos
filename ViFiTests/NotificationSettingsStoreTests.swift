import Foundation
import Testing
@testable import ViFi

@MainActor
@Suite("NotificationSettingsStore", .timeLimit(.minutes(1)))
final class NotificationSettingsStoreTests {
    private static let uid = "user-1"

    private let service = ScriptedNotificationSettingsService()
    private let store: NotificationSettingsStore
    private var observation: Task<Void, Never>?

    init() {
        store = NotificationSettingsStore(service: service, saveTimeout: .milliseconds(150))
    }

    deinit {
        observation?.cancel()
    }

    // MARK: - Reading

    @Test("Before the record is delivered the store is loading and nothing is allowed")
    func loadingAllowsNothing() {
        #expect(!store.isLoaded)
        #expect(store.availability == .loading)
        #expect(!store.hasAnswered)
        #expect(!store.marketingEnabled)
    }

    @Test("A user who never answered is loaded, unanswered, and campaigns are off")
    func neverAnswered() async {
        service.feed = .success(nil)

        await startObserving()

        #expect(store.isLoaded)
        #expect(!store.hasAnswered)
        #expect(!store.marketingEnabled)
        #expect(service.openedUsers == [Self.uid])
    }

    @Test("The stored answer is followed live")
    func followsTheRecord() async {
        service.feed = .success(NotificationConsent(marketing: false))
        await startObserving()
        #expect(store.hasAnswered)
        #expect(!store.marketingEnabled)

        service.emit(.success(NotificationConsent(marketing: true)))
        #expect(await eventually { store.marketingEnabled })
    }

    @Test("A record that cannot be read is unavailable, never an answer")
    func unreadable() async {
        service.feed = .failure(.unavailable)

        await startObserving()

        #expect(store.availability == .unavailable)
        #expect(!store.isLoaded)
        #expect(!store.hasAnswered)
        #expect(!store.marketingEnabled)
    }

    @Test("Reset forgets the answer and the user, so the next user never inherits it")
    func resetForgets() async {
        service.feed = .success(NotificationConsent(marketing: true))
        await startObserving()
        #expect(store.marketingEnabled)

        store.reset()

        #expect(!store.marketingEnabled)
        #expect(!store.hasAnswered)
        #expect(store.availability == .loading)
        #expect(await store.setMarketing(true, source: .settings) == false, "No user, no write")
        #expect(service.writes.isEmpty)
    }

    @Test("Observing another user clears the previous one's answer until theirs arrives")
    func anotherUser() async {
        service.feed = .success(NotificationConsent(marketing: true))
        await startObserving()
        #expect(store.marketingEnabled)
        observation?.cancel()

        service.feed = nil
        observation = Task { await store.observe(uid: "user-2") }

        #expect(await eventually { service.openedUsers == [Self.uid, "user-2"] })
        #expect(!store.marketingEnabled)
        #expect(store.availability == .loading)
    }

    @Test("A value delivered for a user who has since signed out never lands on the next one")
    func staleValueAfterResetIsIgnored() async {
        service.feed = nil
        observation = Task { await store.observe(uid: Self.uid) }
        #expect(await eventually { service.openedUsers == [Self.uid] })

        store.reset()
        service.emit(.success(NotificationConsent(marketing: true)))
        // Let the stream deliver; a missing guard would apply the value here.
        try? await Task.sleep(for: .milliseconds(50))

        #expect(!store.marketingEnabled)
        #expect(!store.hasAnswered)
        #expect(store.availability == .loading)
    }

    @Test("A failure delivered for a user who has since signed out does not mark the next one unavailable")
    func staleFailureAfterResetIsIgnored() async {
        service.feed = nil
        observation = Task { await store.observe(uid: Self.uid) }
        #expect(await eventually { service.openedUsers == [Self.uid] })

        store.reset()
        service.emit(.failure(.unavailable))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(store.availability == .loading)
    }

    // MARK: - Waiting

    @Test("Waiting returns as soon as the record is loaded")
    func waitReturnsWhenLoaded() async {
        service.feed = nil
        observation = Task { await store.observe(uid: Self.uid) }
        #expect(await eventually { service.openedUsers == [Self.uid] })

        let waiting = Task { await store.waitUntilLoaded(timeout: .seconds(5)) }
        service.emit(.success(nil))

        #expect(await waiting.value)
    }

    @Test("Waiting gives up after the timeout")
    func waitTimesOut() async {
        service.feed = nil
        observation = Task { await store.observe(uid: Self.uid) }
        #expect(await eventually { service.openedUsers == [Self.uid] })

        #expect(await store.waitUntilLoaded(timeout: .milliseconds(80)) == false)
    }

    // MARK: - Writing

    @Test("An answer is written with its source for the signed-in user and shows right away")
    func writesTheAnswer() async {
        await startObserving()

        let saved = await store.setMarketing(true, source: .prompt)

        #expect(saved)
        #expect(service.writes == [.init(marketing: true, source: .prompt, uid: Self.uid)])
        #expect(store.marketingEnabled)
        #expect(store.hasAnswered)
    }

    @Test("A switch change from Account is written as a settings answer")
    func writesFromSettings() async {
        service.feed = .success(NotificationConsent(marketing: true))
        await startObserving()

        await store.setMarketing(false, source: .settings)

        #expect(service.writes == [.init(marketing: false, source: .settings, uid: Self.uid)])
        #expect(!store.marketingEnabled)
        #expect(store.hasAnswered)
    }

    @Test("A rejected write puts the previous answer back")
    func rejectedWriteReverts() async {
        service.feed = .success(NotificationConsent(marketing: false))
        service.writeError = ConsentWriteRejected()
        await startObserving()

        let saved = await store.setMarketing(true, source: .settings)

        #expect(!saved)
        #expect(!store.marketingEnabled)
        #expect(store.hasAnswered, "The earlier answer stays")
    }

    @Test("A rejected first answer leaves the user unanswered")
    func rejectedFirstAnswer() async {
        service.writeError = ConsentWriteRejected()
        await startObserving()

        #expect(await store.setMarketing(true, source: .prompt) == false)

        #expect(!store.hasAnswered)
        #expect(!store.marketingEnabled)
    }

    @Test("A write the server does not acknowledge in time (offline) counts as saved and stays shown")
    func unacknowledgedWriteIsQueued() async {
        let gate = AsyncGate()
        service.writeGate = gate
        await startObserving()

        let saved = await store.setMarketing(true, source: .settings)

        #expect(saved)
        #expect(store.marketingEnabled)
        #expect(service.writes.count == 1)
        gate.open()
    }

    // MARK: - Helpers

    private func startObserving() async {
        observation = Task { await store.observe(uid: Self.uid) }
        #expect(await eventually { service.openedUsers.contains(Self.uid) })
        // `nil` feed stays silent; otherwise wait for the first delivery to land.
        if service.feed != nil {
            #expect(await eventually { store.availability != .loading })
        }
    }
}

import Foundation
import Testing
@testable import ViFi

@Suite("ProfileStore", .timeLimit(.minutes(1)))
struct ProfileStoreTests {
    @Test("It starts loading")
    func startsLoading() {
        let store = ProfileStore(service: StubProfileService())
        #expect(store.state == .loading)
        #expect(store.profile == nil)
    }

    @Test("A stored profile loads as present")
    func loadsPresent() async {
        let service = StubProfileService(loadReplies: [.success(Fixture.profile)])
        let store = ProfileStore(service: service)

        await store.load(uid: Fixture.user.id)

        #expect(store.state == .present(Fixture.profile))
        #expect(store.profile == Fixture.profile)
        #expect(service.calls == [.load(uid: Fixture.user.id)])
    }

    @Test("A missing profile loads as absent")
    func loadsAbsent() async {
        let store = ProfileStore(service: StubProfileService(loadReplies: [.success(nil)]))

        await store.load(uid: Fixture.user.id)

        #expect(store.state == .absent)
    }

    @Test("A failed read is surfaced, not treated as absent")
    func loadFailure() async {
        let store = ProfileStore(service: StubProfileService(loadReplies: [.failure(ProfileError.offline)]))

        await store.load(uid: Fixture.user.id)

        #expect(store.state == .failed(ProfileError.offline.userMessage))
        #expect(store.profile == nil)
    }

    @Test("Updating opens the gate without a reload")
    func updateOpensGate() {
        let store = ProfileStore(service: StubProfileService())

        store.update(Fixture.profile)

        #expect(store.state == .present(Fixture.profile))
    }

    @Test("Reset clears back to loading")
    func resetClears() async {
        let store = ProfileStore(service: StubProfileService(loadReplies: [.success(Fixture.profile)]))
        await store.load(uid: Fixture.user.id)

        store.reset()

        #expect(store.state == .loading)
    }

    @Test("Re-reading the same user keeps the profile visible (no spinner flash)")
    func reloadSameUserKeepsProfile() async {
        let service = StubProfileService(loadReplies: [.success(Fixture.profile)])
        let store = ProfileStore(service: service)
        await store.load(uid: Fixture.user.id)
        #expect(store.state == .present(Fixture.profile))

        let gate = AsyncGate()
        service.gate = gate
        let reload = Task { await store.load(uid: Fixture.user.id) }
        await gate.waitForArrival()
        #expect(store.state == .present(Fixture.profile), "Same user should not flash the loading state")

        gate.open()
        await reload.value
        #expect(store.state == .present(Fixture.profile))
    }

    @Test("Loading a different user shows the loading state")
    func loadingDifferentUserShowsLoading() async {
        let service = StubProfileService(loadReplies: [.success(Fixture.profile)])
        let store = ProfileStore(service: service)
        await store.load(uid: Fixture.user.id)

        let gate = AsyncGate()
        service.gate = gate
        let reload = Task { await store.load(uid: "user-2") }
        await gate.waitForArrival()
        #expect(store.state == .loading)

        gate.open()
        await reload.value
    }
}

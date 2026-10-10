import Foundation
import Testing
@testable import ViFi

@Suite("SessionStore", .timeLimit(.minutes(1)))
struct SessionStoreTests {
    private let otherUser = AuthUser(id: "user-2", phoneNumber: "+905559998877")

    // MARK: - Initial state

    @Test("Without a restored session the state is unknown")
    func unknownAtLaunch() {
        let store = SessionStore(auth: StubAuthService())

        #expect(store.state == .unknown)
        #expect(store.user == nil)
    }

    @Test("A session the service already has starts signed in")
    func signedInAtLaunch() {
        let store = SessionStore(auth: StubAuthService(currentUser: Fixture.user))

        #expect(store.state == .signedIn(Fixture.user))
        #expect(store.user == Fixture.user)
    }

    // MARK: - Following changes

    @Test("The first report without a user means signed out")
    func firstReportSignedOut() async {
        let auth = StubAuthService()
        let store = SessionStore(auth: auth)

        await observe(store, auth: auth) {}

        #expect(store.state == .signedOut)
        #expect(store.user == nil)
    }

    @Test("The first report with a user means signed in")
    func firstReportSignedIn() async {
        let auth = StubAuthService(currentUser: Fixture.user)
        let store = SessionStore(auth: auth)

        await observe(store, auth: auth) {}

        #expect(store.state == .signedIn(Fixture.user))
    }

    @Test("Signing in and out moves the state along")
    func signInThenOut() async {
        let auth = StubAuthService()
        let store = SessionStore(auth: auth)
        let observation = Task { await store.observeUserChanges() }

        #expect(await eventually { store.state == .signedOut })
        auth.emit(Fixture.user)
        #expect(await eventually { store.state == .signedIn(Fixture.user) })
        #expect(store.user == Fixture.user)
        auth.emit(nil)
        #expect(await eventually { store.state == .signedOut })
        #expect(store.user == nil)

        observation.cancel()
        await observation.value
    }

    @Test("Another user signing in replaces the previous one")
    func userSwitch() async {
        let auth = StubAuthService(currentUser: Fixture.user)
        let store = SessionStore(auth: auth)

        await observe(store, auth: auth) {
            auth.emit(otherUser)
        }

        #expect(store.state == .signedIn(otherUser))
    }

    @Test("A session revoked elsewhere signs the user out")
    func revokedSession() async {
        let auth = StubAuthService(currentUser: Fixture.user)
        let store = SessionStore(auth: auth)

        await observe(store, auth: auth) {
            auth.emit(nil)
        }

        #expect(store.state == .signedOut)
    }

    @Test("Signing out through the service reaches the store")
    func signOutThroughService() async throws {
        let auth = StubAuthService(currentUser: Fixture.user)
        let store = SessionStore(auth: auth)

        await observe(store, auth: auth) {
            try? auth.signOut()
        }

        #expect(store.state == .signedOut)
        #expect(auth.calls == [.signOut])
    }

    @Test("Deleting the account through the service reaches the store")
    func deleteThroughService() async {
        let auth = StubAuthService(currentUser: Fixture.user)
        let store = SessionStore(auth: auth)
        let observation = Task { await store.observeUserChanges() }
        #expect(await eventually { store.state == .signedIn(Fixture.user) })

        try? await auth.deleteAccount()

        #expect(await eventually { store.state == .signedOut })
        observation.cancel()
        await observation.value
    }

    @Test("Observing ends when the calling task is cancelled")
    func observationEndsOnCancellation() async {
        let auth = StubAuthService()
        let store = SessionStore(auth: auth)
        let observation = Task { await store.observeUserChanges() }
        #expect(await eventually { store.state == .signedOut })

        observation.cancel()
        await observation.value

        auth.emit(Fixture.user)
        await Task.yield()
        #expect(store.state == .signedOut, "A cancelled observer no longer follows changes")
    }

    @Test("Reporting the same user again keeps the state")
    func repeatedReport() async {
        let auth = StubAuthService(currentUser: Fixture.user)
        let store = SessionStore(auth: auth)

        await observe(store, auth: auth) {
            auth.emit(Fixture.user)
            auth.emit(Fixture.user)
        }

        #expect(store.state == .signedIn(Fixture.user))
    }

    // MARK: - Helpers

    /// Observes `store` while `changes` runs, until every reported change has been applied.
    private func observe(_ store: SessionStore, auth: StubAuthService, changes: () -> Void) async {
        let observation = Task { await store.observeUserChanges() }
        // Changes are reported to streams that exist, so wait until the store is listening.
        #expect(await eventually { auth.observerCount > 0 })
        changes()
        auth.finishUserChanges()
        await observation.value
    }
}

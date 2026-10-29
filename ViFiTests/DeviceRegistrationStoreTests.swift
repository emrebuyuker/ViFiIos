import FirebaseFirestore
import Foundation
import Testing
@testable import ViFi

@Suite("DeviceRegistrationStore", .timeLimit(.minutes(1)))
struct DeviceRegistrationStoreTests {
    private let registrar = SpyDeviceRegistrar()

    // MARK: - Registering

    @Test("A token that arrives before sign-in is registered when the user signs in")
    func tokenThenSignIn() async {
        let store = makeStore()

        store.tokenDidChange("token-1")
        #expect(registrar.registered.isEmpty)
        store.userDidSignIn(uid: "user-1")

        #expect(await eventually { registrar.registered.count == 1 })
        #expect(registrar.registered.first?.token == "token-1")
        #expect(registrar.registered.first?.uid == "user-1")
    }

    @Test("A token that arrives after sign-in is registered right away")
    func signInThenToken() async {
        let store = makeStore()

        store.userDidSignIn(uid: "user-1")
        #expect(registrar.registered.isEmpty)
        store.tokenDidChange("token-1")

        #expect(await eventually { registrar.registered.count == 1 })
    }

    @Test("The same token and user is registered once, however often it is reported")
    func registersOnce() async {
        let store = makeStore()
        store.userDidSignIn(uid: "user-1")
        store.tokenDidChange("token-1")
        #expect(await eventually { registrar.registered.count == 1 })

        store.tokenDidChange("token-1")
        store.userDidSignIn(uid: "user-1")
        try? await Task.sleep(for: .milliseconds(30))

        #expect(registrar.registered.count == 1)
    }

    @Test("A refreshed token is registered again")
    func refreshedToken() async {
        let store = makeStore()
        store.userDidSignIn(uid: "user-1")
        store.tokenDidChange("token-1")
        #expect(await eventually { registrar.registered.count == 1 })

        store.tokenDidChange("token-2")

        #expect(await eventually { registrar.registered.count == 2 })
        #expect(registrar.registered.last?.token == "token-2")
    }

    @Test("A blank token is ignored")
    func blankToken() async {
        let store = makeStore()
        store.userDidSignIn(uid: "user-1")

        store.tokenDidChange("  ")
        store.tokenDidChange(nil)
        try? await Task.sleep(for: .milliseconds(30))

        #expect(registrar.registered.isEmpty)
        #expect(store.token == nil)
    }

    @Test("Another user signing in on the same device registers the token under them")
    func userSwitch() async {
        let store = makeStore()
        store.tokenDidChange("token-1")
        store.userDidSignIn(uid: "user-1")
        #expect(await eventually { registrar.registered.count == 1 })

        store.userDidSignOut()
        store.userDidSignIn(uid: "user-2")

        #expect(await eventually { registrar.registered.count == 2 })
        #expect(registrar.registered.last?.uid == "user-2")
    }

    @Test("Signing out stops registrations: a token refresh while signed out writes nothing")
    func nothingWhileSignedOut() async {
        let store = makeStore()
        store.userDidSignIn(uid: "user-1")
        store.tokenDidChange("token-1")
        #expect(await eventually { registrar.registered.count == 1 })

        store.userDidSignOut()
        store.tokenDidChange("token-2")
        try? await Task.sleep(for: .milliseconds(30))

        #expect(registrar.registered.count == 1)
    }

    @Test("A failed registration is retried at the next trigger")
    func failureIsRetried() async {
        registrar.registerError = DeviceError.offline
        let store = makeStore()
        store.userDidSignIn(uid: "user-1")
        store.tokenDidChange("token-1")
        #expect(await eventually { registrar.registered.count == 1 })
        try? await Task.sleep(for: .milliseconds(30))

        registrar.registerError = nil
        store.userDidSignIn(uid: "user-1")

        #expect(await eventually { registrar.registered.count == 2 })
    }

    // MARK: - Unregistering

    @Test("Unregistering removes the device from that user and stops further registrations")
    func unregisters() async {
        let store = makeStore()
        store.userDidSignIn(uid: "user-1")
        store.tokenDidChange("token-1")
        #expect(await eventually { registrar.registered.count == 1 })

        await store.unregister(uid: "user-1")
        store.tokenDidChange("token-2")
        try? await Task.sleep(for: .milliseconds(30))

        #expect(registrar.unregistered == ["user-1"])
        #expect(registrar.registered.count == 1, "A token refresh before the sign-out finishes must not bring the device back")
        #expect(store.userId == nil)
    }

    @Test("A failed removal never throws, so signing out can carry on")
    func unregisterFailureIsSwallowed() async {
        registrar.unregisterError = DeviceError.offline
        let store = makeStore()

        await store.unregister(uid: "user-1")

        #expect(registrar.unregistered == ["user-1"])
    }

    @Test("A removal the server never answers is given up on after the timeout")
    func unregisterTimesOut() async {
        let hanging = HangingDeviceRegistrar()
        let store = DeviceRegistrationStore(registrar: hanging, unregisterTimeout: .milliseconds(50))
        let start = ContinuousClock.now

        await store.unregister(uid: "user-1")

        #expect(ContinuousClock.now - start < .seconds(5))
        #expect(hanging.gate.arrivals == 1)
        hanging.gate.open()
    }

    // MARK: - Helpers

    private func makeStore() -> DeviceRegistrationStore {
        DeviceRegistrationStore(registrar: registrar, unregisterTimeout: .seconds(2))
    }

    private enum DeviceError: Error {
        case offline
    }
}

@Suite("FirebaseDeviceRegistrar")
struct FirebaseDeviceRegistrarTests {
    @Test("The document body is exactly what the security rules accept")
    func documentFields() {
        let fields = FirebaseDeviceRegistrar.fields(token: "fcm-token", appVersion: "4.1.0")

        #expect(Set(fields.keys) == ["token", "platform", "appVersion", "updatedAt"])
        #expect(fields["token"] as? String == "fcm-token")
        #expect(fields["platform"] as? String == "ios")
        #expect(fields["appVersion"] as? String == "4.1.0")
        #expect(fields["updatedAt"] is FieldValue)
    }

    @Test("An over-long app version is cut to the 32 characters the rules allow")
    func clipsAppVersion() {
        let fields = FirebaseDeviceRegistrar.fields(token: "t", appVersion: String(repeating: "9", count: 60))

        #expect((fields["appVersion"] as? String)?.count == 32)
    }

    @Test("The installation id is created once and then stays the same")
    func installationIdIsStable() throws {
        let storage = try TemporaryDefaults()

        let first = DeviceInstallationID.current(in: storage.defaults)
        let second = DeviceInstallationID.current(in: storage.defaults)

        #expect(first == second)
        #expect(DeviceInstallationID.isValid(first))
    }

    @Test("A fresh install gets its own id")
    func installationIdIsPerInstall() throws {
        let one = try TemporaryDefaults()
        let two = try TemporaryDefaults()

        #expect(DeviceInstallationID.current(in: one.defaults) != DeviceInstallationID.current(in: two.defaults))
    }

    @Test("A stored id that is not a valid document id is replaced")
    func invalidStoredIdIsReplaced() throws {
        let storage = try TemporaryDefaults()
        storage.defaults.set("not/valid", forKey: "notifications.installationId.v1")

        let id = DeviceInstallationID.current(in: storage.defaults)

        #expect(DeviceInstallationID.isValid(id))
        #expect(id != "not/valid")
    }

    @Test("Only ids matching the rules' pattern are valid", arguments: [
        ("abc-DEF_123", true),
        ("", false),
        ("has space", false),
        ("slash/id", false),
        ("ünicode", false),
        (String(repeating: "a", count: 128), true),
        (String(repeating: "a", count: 129), false),
    ])
    func validity(id: String, expected: Bool) {
        #expect(DeviceInstallationID.isValid(id) == expected)
    }
}

@Suite("FirebaseInboxReader.item")
struct FirebaseInboxReaderTests {
    @Test("Timestamps become dates before the shared parser sees the document")
    func convertsTimestamps() throws {
        let created = Date(timeIntervalSince1970: 1_761_700_000)
        let expires = Date(timeIntervalSince1970: 1_761_800_000)

        let item = try #require(FirebaseInboxReader.item(id: "n-1", source: .personal, data: [
            "title": "Merhaba",
            "kind": "system",
            "createdAt": Timestamp(date: created),
            "expiresAt": Timestamp(date: expires),
        ]))

        #expect(item.createdAt == created)
        #expect(item.expiresAt == expires)
        #expect(item.kind == .system)
        #expect(item.source == .personal)
    }

    @Test("A legacy announcement parses as a general broadcast")
    func legacyAnnouncement() throws {
        let item = try #require(FirebaseInboxReader.item(id: "AbC123", source: .broadcast, data: [
            "title": "Hoş geldin",
            "body": "Merhaba",
            "createdAt": Timestamp(date: Date(timeIntervalSince1970: 1_700_000_000)),
        ]))

        #expect(item.kind == .general)
        #expect(item.action == nil)
    }

    @Test("A document without a title is dropped")
    func titleRequired() {
        #expect(FirebaseInboxReader.item(id: "n-1", source: .broadcast, data: ["body": "x"]) == nil)
    }
}

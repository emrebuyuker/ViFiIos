@preconcurrency import FirebaseFirestore
import Foundation

/// Stores this device's FCM token in Cloud Firestore (`users/{uid}/devices/{installationId}`, `vifi` database;
/// NOTIFICATIONS.md §3.5), so the server can push targeted and personal notifications to it.
///
/// The document id is the per-install `DeviceInstallationID`. Fields are exactly the ones the rules accept —
/// `{token, platform, appVersion, updatedAt}` — with a server timestamp. The owner writes and deletes their own
/// devices; a sign-out removes this one first (`DeviceRegistrationStore`).
final class FirebaseDeviceRegistrar: DeviceRegistering {
    private static let collection = "users"
    private static let subcollection = "devices"

    private let firestore: Firestore
    private let defaults: UserDefaults
    private let appVersion: String

    init(
        firestore: Firestore = ViFiFirestore.shared,
        defaults: UserDefaults = .standard,
        appVersion: String = Bundle.main.shortVersionString
    ) {
        self.firestore = firestore
        self.defaults = defaults
        self.appVersion = appVersion
    }

    func register(token: String, uid: String) async throws {
        let fields = Self.fields(token: token, appVersion: appVersion)
        try await document(uid: uid).setData(fields)
    }

    func unregister(uid: String) async throws {
        try await document(uid: uid).delete()
    }

    private func document(uid: String) -> DocumentReference {
        firestore.collection(Self.collection).document(uid)
            .collection(Self.subcollection).document(DeviceInstallationID.current(in: defaults))
    }

    /// The document body the rules accept: exactly `{token, platform, appVersion, updatedAt}`.
    nonisolated static func fields(token: String, appVersion: String) -> [String: Any] {
        [
            "token": token,
            "platform": "ios",
            "appVersion": String(appVersion.prefix(32)),
            "updatedAt": FieldValue.serverTimestamp(),
        ]
    }
}

/// The per-install id that names this device's registration document: a random UUID created on first use and
/// kept in `UserDefaults`. It is stable for the life of the installation (a refreshed token updates the same
/// document); a fresh install starts a new one, and the old document goes away with its dead token.
nonisolated enum DeviceInstallationID {
    // Bump the suffix on an incompatible change: the old key is then ignored.
    private static let key = "notifications.installationId.v1"

    /// The stored id, created (and stored) when there is none or the stored value is not a valid document id.
    static func current(in defaults: UserDefaults) -> String {
        if let stored = defaults.string(forKey: key), isValid(stored) {
            return stored
        }
        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: key)
        return created
    }

    /// Whether `id` can be a device document id (`^[A-Za-z0-9_-]{1,128}$`, as the security rules require).
    static func isValid(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
        }
    }
}

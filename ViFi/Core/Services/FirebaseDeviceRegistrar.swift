import Foundation

/// Stores this device's FCM token in Cloud Firestore (`users/{uid}/devices/{installationId}`).
///
/// Placeholder until the client track ships (NOTIFICATIONS.md phase 1, track B): registering does nothing yet,
/// so devices keep receiving only the broadcast topic, as before.
final class FirebaseDeviceRegistrar: DeviceRegistering {
    func register(token: String, uid: String) async throws {}

    func unregister(uid: String) async throws {}
}

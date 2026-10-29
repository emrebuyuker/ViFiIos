import Foundation

/// Keeps this device's push token under the signed-in user (`users/{uid}/devices/{installationId}`,
/// NOTIFICATIONS.md §3.5), so targeted and personal notifications can reach it.
protocol DeviceRegistering: AnyObject {
    /// Saves `token` for `uid`. Idempotent; called after sign-in and whenever the token changes.
    func register(token: String, uid: String) async throws
    /// Removes this device from `uid`. Called before signing out, while the user can still write.
    func unregister(uid: String) async throws
}

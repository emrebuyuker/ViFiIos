import Foundation

/// Whether the app may read the device's location while it is in use.
nonisolated enum LocationAuthorization: Equatable, Sendable {
    /// Never asked: the location picker asks once, when it opens.
    case notDetermined
    /// Refused, or not allowed by restrictions (parental controls, device management). The picker works without it.
    case denied
    /// Allowed while the app is in use.
    case authorized
}

/// One location fix of the device.
nonisolated struct DeviceCoordinate: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    /// The radius of uncertainty in meters: a few meters with precise location, kilometers with approximate.
    let accuracy: Double
}

/// The device's location, used only by the admin's location picker to center the map on where the admin is.
/// It is shown on the map and never stored or sent anywhere.
///
/// Behind a protocol so tests can script it and so mock mode, previews and builds without a Maps key never touch
/// CoreLocation: only `GoogleLocationPicker` creates the live `CoreLocationProvider`.
protocol DeviceLocating: AnyObject {
    /// The current permission, without asking for it.
    var authorization: LocationAuthorization { get }
    /// Asks for the When-In-Use permission if it was never asked and returns the answer; otherwise returns the
    /// current permission without asking again.
    func requestAuthorization() async -> LocationAuthorization
    /// One fix of the device's location, or `nil` when it cannot be determined (or the wait was cancelled).
    func currentLocation() async -> DeviceCoordinate?
}

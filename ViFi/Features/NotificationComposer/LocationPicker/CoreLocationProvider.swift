import CoreLocation
import OSLog

/// `DeviceLocating` on CoreLocation, for the admin's location picker.
///
/// The `CLLocationManager` is created on first use, not with this object, so building a picker that never asks
/// costs nothing. It lives on the main actor: the manager is created on the main thread, so its delegate callbacks
/// arrive there too. A fix is only handed to the picker to move the map; it is never logged, stored or sent.
final class CoreLocationProvider: NSObject, DeviceLocating {
    private var manager: CLLocationManager?
    private var authorizationWaiters: [CheckedContinuation<LocationAuthorization, Never>] = []
    private var locationWaiters: [CheckedContinuation<DeviceCoordinate?, Never>] = []

    var authorization: LocationAuthorization {
        Self.authorization(from: locationManager.authorizationStatus)
    }

    func requestAuthorization() async -> LocationAuthorization {
        let current = authorization
        guard current == .notDetermined, !Task.isCancelled else { return current }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                authorizationWaiters.append(continuation)
                // Asking again while the system prompt is up is a no-op; the answer resumes every waiter.
                locationManager.requestWhenInUseAuthorization()
            }
        } onCancel: {
            Task { @MainActor in self.resumeAuthorizationWaiters(with: self.authorization) }
        }
    }

    func currentLocation() async -> DeviceCoordinate? {
        guard authorization == .authorized, !Task.isCancelled else { return nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let isAlreadyLocating = !locationWaiters.isEmpty
                locationWaiters.append(continuation)
                if !isAlreadyLocating {
                    // One fix, delivered once (or as a failure) to the delegate.
                    locationManager.requestLocation()
                }
            }
        } onCancel: {
            Task { @MainActor in self.resumeLocationWaiters(with: nil) }
        }
    }

    // MARK: - Private

    private var locationManager: CLLocationManager {
        if let manager {
            return manager
        }
        let created = CLLocationManager()
        created.delegate = self
        // Enough to center a street-level map; a finer fix only takes longer.
        created.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager = created
        return created
    }

    private func resumeAuthorizationWaiters(with authorization: LocationAuthorization) {
        let waiters = authorizationWaiters
        authorizationWaiters.removeAll()
        waiters.forEach { $0.resume(returning: authorization) }
    }

    private func resumeLocationWaiters(with coordinate: DeviceCoordinate?) {
        guard !locationWaiters.isEmpty else { return }
        let waiters = locationWaiters
        locationWaiters.removeAll()
        if coordinate == nil {
            // Cancels a fix still in progress (a cancelled wait, or a failure that needs no more attempts).
            manager?.stopUpdatingLocation()
        }
        waiters.forEach { $0.resume(returning: coordinate) }
    }

    private static func authorization(from status: CLAuthorizationStatus) -> LocationAuthorization {
        switch status {
        case .notDetermined:
            .notDetermined
        case .authorizedWhenInUse, .authorizedAlways:
            .authorized
        case .denied, .restricted:
            .denied
        @unknown default:
            .denied
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension CoreLocationProvider: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let authorization = Self.authorization(from: manager.authorizationStatus)
        // The first callback comes right after the manager is created, before the admin has answered.
        guard authorization != .notDetermined else { return }
        resumeAuthorizationWaiters(with: authorization)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last,
              location.horizontalAccuracy >= 0,
              CLLocationCoordinate2DIsValid(location.coordinate) else {
            resumeLocationWaiters(with: nil)
            return
        }
        resumeLocationWaiters(with: DeviceCoordinate(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy
        ))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // The reason only (no coordinates): denied, no fix available, and so on.
        Logger.app.notice("Device location unavailable: \(error.localizedDescription, privacy: .public)")
        resumeLocationWaiters(with: nil)
    }
}

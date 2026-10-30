import GoogleMaps
import SwiftUI

/// A Google map for the location picker. It reports where it comes to rest (the picker's pin is fixed on top of
/// its center, so that is the chosen coordinate), when the admin starts moving it, and taps on places (shop and
/// landmark labels); it moves where the picker asks it to.
///
/// It shows the device's location (the blue dot and the button that re-centers on it) only when
/// `showsDeviceLocation` is on, which the picker sets once the location permission is granted; the map never asks
/// for it. `GoogleMapsSDK.startIfPossible()` must have succeeded first; a `GMSMapView` created without an API key
/// throws.
struct GoogleMapView: UIViewRepresentable {
    /// What happened on the map.
    enum Event {
        /// The map came to rest. `visibleRadius` is the distance from the center to the corners, in meters.
        case settled(latitude: Double, longitude: Double, zoom: Float, visibleRadius: Double)
        /// The admin started a drag or pinch.
        case gestureBegan
        /// The admin tapped a place's label.
        case placeTapped(placeId: String, name: String, latitude: Double, longitude: Double)
    }

    let initialCamera: MapCamera
    let cameraRequest: CameraRequest?
    let showsDeviceLocation: Bool
    let onEvent: (Event) -> Void

    func makeUIView(context: Context) -> GMSMapView {
        let options = GMSMapViewOptions()
        options.camera = GMSCameraPosition(
            latitude: initialCamera.latitude,
            longitude: initialCamera.longitude,
            zoom: initialCamera.zoom
        )
        let mapView = GMSMapView(options: options)
        mapView.delegate = context.coordinator
        mapView.isMyLocationEnabled = showsDeviceLocation
        mapView.settings.myLocationButton = showsDeviceLocation
        mapView.settings.compassButton = false
        mapView.settings.rotateGestures = false
        mapView.settings.tiltGestures = false
        return mapView
    }

    func updateUIView(_ mapView: GMSMapView, context: Context) {
        context.coordinator.onEvent = onEvent
        if mapView.isMyLocationEnabled != showsDeviceLocation {
            mapView.isMyLocationEnabled = showsDeviceLocation
            mapView.settings.myLocationButton = showsDeviceLocation
        }
        guard let request = cameraRequest, request.id != context.coordinator.handledRequestId else { return }
        context.coordinator.handledRequestId = request.id
        let camera = request.camera
        mapView.animate(to: GMSCameraPosition(latitude: camera.latitude, longitude: camera.longitude, zoom: camera.zoom))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onEvent: onEvent)
    }

    final class Coordinator: NSObject, GMSMapViewDelegate {
        var onEvent: (Event) -> Void
        /// The last camera request acted on, so a redraw does not replay it.
        var handledRequestId: Int?

        init(onEvent: @escaping (Event) -> Void) {
            self.onEvent = onEvent
        }

        func mapView(_ mapView: GMSMapView, willMove gesture: Bool) {
            // Moves the picker asked for (and the my-location button) are not the admin taking over.
            if gesture {
                onEvent(.gestureBegan)
            }
        }

        func mapView(_ mapView: GMSMapView, idleAt position: GMSCameraPosition) {
            let region = mapView.projection.visibleRegion()
            onEvent(.settled(
                latitude: position.target.latitude,
                longitude: position.target.longitude,
                zoom: position.zoom,
                visibleRadius: GMSGeometryDistance(region.nearLeft, region.farRight) / 2
            ))
        }

        func mapView(
            _ mapView: GMSMapView,
            didTapPOIWithPlaceID placeID: String,
            name: String,
            location: CLLocationCoordinate2D
        ) {
            onEvent(.placeTapped(placeId: placeID, name: name, latitude: location.latitude, longitude: location.longitude))
        }
    }
}

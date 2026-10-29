import GoogleMaps
import SwiftUI

/// A Google map for the location picker. It reports where it comes to rest (the picker's pin is fixed on top of
/// its center, so that is the chosen coordinate) and moves where the picker asks it to.
///
/// Deliberately has no "my location": no CoreLocation permission is requested and no location data is read.
/// `GoogleMapsSDK.startIfPossible()` must have succeeded first; a `GMSMapView` created without an API key throws.
struct GoogleMapView: UIViewRepresentable {
    let initialCamera: MapCamera
    let cameraRequest: CameraRequest?
    let onSettle: (_ latitude: Double, _ longitude: Double) -> Void

    func makeUIView(context: Context) -> GMSMapView {
        let options = GMSMapViewOptions()
        options.camera = GMSCameraPosition(
            latitude: initialCamera.latitude,
            longitude: initialCamera.longitude,
            zoom: initialCamera.zoom
        )
        let mapView = GMSMapView(options: options)
        mapView.delegate = context.coordinator
        mapView.isMyLocationEnabled = false
        mapView.settings.myLocationButton = false
        mapView.settings.compassButton = false
        mapView.settings.rotateGestures = false
        mapView.settings.tiltGestures = false
        return mapView
    }

    func updateUIView(_ mapView: GMSMapView, context: Context) {
        context.coordinator.onSettle = onSettle
        guard let request = cameraRequest, request.id != context.coordinator.handledRequestId else { return }
        context.coordinator.handledRequestId = request.id
        let camera = request.camera
        mapView.animate(to: GMSCameraPosition(latitude: camera.latitude, longitude: camera.longitude, zoom: camera.zoom))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSettle: onSettle)
    }

    final class Coordinator: NSObject, GMSMapViewDelegate {
        var onSettle: (Double, Double) -> Void
        /// The last camera request acted on, so a redraw does not replay it.
        var handledRequestId: Int?

        init(onSettle: @escaping (Double, Double) -> Void) {
            self.onSettle = onSettle
        }

        func mapView(_ mapView: GMSMapView, idleAt position: GMSCameraPosition) {
            onSettle(position.target.latitude, position.target.longitude)
        }
    }
}

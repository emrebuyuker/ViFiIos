import SwiftUI

/// Provides the screen on which an admin picks a campaign's location, presented full screen from the composer.
///
/// Behind a protocol so the Google SDKs stay out of mock mode: the app uses `GoogleLocationPicker`, and
/// `-ViFiMockData` (UI tests, previews) uses a stub that offers a fixed place.
protocol LocationPicking {
    /// The picker screen. Calls `onPick` with a valid location, or `onCancel` when the admin backs out; the caller
    /// dismisses it in both cases.
    /// - Parameter initial: The location being changed, if any; the map starts on it.
    func makePicker(
        initial: NotificationLocation?,
        onPick: @escaping (NotificationLocation) -> Void,
        onCancel: @escaping () -> Void
    ) -> AnyView
}

/// The production picker: a Google map with a Places search that opens on the device's location (When-In-Use
/// permission, asked when it opens). Without a configured API key it shows an explanation instead of a map (the
/// Maps SDK would throw) and touches neither the Google SDKs nor CoreLocation.
struct GoogleLocationPicker: LocationPicking {
    func makePicker(
        initial: NotificationLocation?,
        onPick: @escaping (NotificationLocation) -> Void,
        onCancel: @escaping () -> Void
    ) -> AnyView {
        guard GoogleMapsSDK.startIfPossible() else {
            return AnyView(LocationPickerUnavailableView(onClose: onCancel))
        }
        // The only place CoreLocation is used: past the key check, so mock mode and keyless builds never reach it.
        return AnyView(LocationPickerView(
            initial: initial,
            searcher: GooglePlacesService(),
            locator: CoreLocationProvider(),
            onPick: onPick,
            onCancel: onCancel
        ))
    }
}

/// Shown instead of the map when the build has no Google Maps API key.
struct LocationPickerUnavailableView: View {
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Harita anahtarı yapılandırılmamış", systemImage: "map")
            } description: {
                Text("Konum seçmek için bu sürümün Google Haritalar anahtarıyla derlenmiş olması gerekir. Geliştirici ekibe haber ver.")
            }
            .accessibilityIdentifier("locationPicker.unavailable")
            .navigationTitle("Konum Seç")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat", action: onClose)
                        .accessibilityIdentifier("locationPicker.cancel")
                }
            }
        }
    }
}

#if DEBUG
#Preview("Harita anahtarı yok") {
    LocationPickerUnavailableView(onClose: {})
}
#endif

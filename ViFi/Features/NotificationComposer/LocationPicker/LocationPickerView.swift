import SwiftUI

/// The admin's location picker: a Google map with a pin fixed at its center (the coordinate is wherever the map
/// is centered), a Places search above it that moves the map to a result, and below it the name and address the
/// notification will show. "Bu konumu seç" hands back a valid `NotificationLocation`.
struct LocationPickerView: View {
    @State private var viewModel: LocationPickerViewModel
    private let onPick: (NotificationLocation) -> Void
    private let onCancel: () -> Void

    init(
        initial: NotificationLocation?,
        searcher: any PlaceSearching,
        onPick: @escaping (NotificationLocation) -> Void,
        onCancel: @escaping () -> Void
    ) {
        _viewModel = State(initialValue: LocationPickerViewModel(initial: initial, searcher: searcher))
        self.onPick = onPick
        self.onCancel = onCancel
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                mapWithPin
                    .overlay(alignment: .top) {
                        LocationPickerSearchPanel(viewModel: viewModel)
                            .padding(12)
                    }
                LocationPickerDetailsCard(viewModel: viewModel) {
                    if let location = viewModel.location {
                        onPick(location)
                    }
                }
            }
            // The map needs room: past this size the search and details would leave none of it.
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            .navigationTitle("Konum Seç")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("İptal", action: onCancel)
                        .accessibilityIdentifier("locationPicker.cancel")
                }
            }
        }
    }

    private var mapWithPin: some View {
        ZStack {
            GoogleMapView(
                initialCamera: viewModel.initialCamera,
                cameraRequest: viewModel.cameraRequest
            ) { latitude, longitude in
                viewModel.mapDidSettle(latitude: latitude, longitude: longitude)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Harita")
            .accessibilityHint("Konum, haritanın ortasındaki iğnenin gösterdiği yerdir.")
            .accessibilityIdentifier("locationPicker.map")

            CenterPin()
        }
    }
}

/// The pin fixed on the center of the map, its tip exactly on the chosen coordinate.
private struct CenterPin: View {
    @ScaledMetric(relativeTo: .title) private var size: CGFloat = 36

    var body: some View {
        ZStack {
            // Where the tip lands, so the exact point stays visible under the pin.
            Circle()
                .fill(.black.opacity(0.35))
                .frame(width: 6, height: 6)
            Image(systemName: "mappin")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.red)
                .shadow(radius: 2, y: 1)
                // The symbol's tip is at the bottom of its glyph; lift it so the tip, not the middle, is the center.
                .offset(y: -size / 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

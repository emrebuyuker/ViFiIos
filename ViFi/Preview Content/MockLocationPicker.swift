#if DEBUG
import SwiftUI

/// The location picker for `-ViFiMockData` (UI tests, previews): no Google SDK is touched and no key is needed.
/// It offers one fixed place, so the composer's location flow can be exercised end to end.
struct MockLocationPicker: LocationPicking {
    /// What "Bu konumu seç" returns when nothing is being changed.
    static let sampleLocation = NotificationLocation(
        latitude: 40.9903,
        longitude: 29.0290,
        name: "ViFi Öğrenci Kafesi",
        address: "Caferağa, Kadıköy, İstanbul",
        placeId: nil
    )

    func makePicker(
        initial: NotificationLocation?,
        onPick: @escaping (NotificationLocation) -> Void,
        onCancel: @escaping () -> Void
    ) -> AnyView {
        AnyView(MockLocationPickerView(location: initial ?? Self.sampleLocation, onPick: onPick, onCancel: onCancel))
    }
}

private struct MockLocationPickerView: View {
    let location: NotificationLocation
    let onPick: (NotificationLocation) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "map")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Örnek harita")
                    .font(.headline)
                Text(location.name)
                    .accessibilityIdentifier("locationPicker.mock.name")
                if let address = location.address {
                    Text(address)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button {
                    onPick(location)
                } label: {
                    Text("Bu konumu seç")
                        .fontWeight(.semibold)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("locationPicker.confirm")
            }
            .padding(24)
            .frame(maxHeight: .infinity)
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
}

#Preview("Örnek konum seçici") {
    MockLocationPicker().makePicker(initial: nil, onPick: { _ in }, onCancel: {})
}
#endif

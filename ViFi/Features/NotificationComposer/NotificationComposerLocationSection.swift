import SwiftUI

/// The rows under "Eylem" while the button opens a place: the place chosen so far, how to pick or change it on
/// the map, and what a location notification always is (a campaign).
struct NotificationComposerLocationRows: View {
    @Bindable var viewModel: NotificationComposerViewModel
    @Environment(AppEnvironment.self) private var environment
    @State private var isPicking = false

    var body: some View {
        if let location = viewModel.location {
            summary(of: location)
        }

        Button(pickTitle, systemImage: "mappin.and.ellipse") {
            isPicking = true
        }
        .accessibilityIdentifier("notificationComposer.location.pick")
        .fullScreenCover(isPresented: $isPicking) {
            environment.locationPicker.makePicker(
                initial: viewModel.location,
                onPick: { location in
                    viewModel.location = location
                    isPicking = false
                },
                onCancel: { isPicking = false }
            )
        }

        Text("Konumlu bildirimler her zaman Kampanya olarak gider ve yalnızca kampanya bildirimlerini açmış kullanıcılara ulaşır.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("notificationComposer.location.note")
    }

    private var pickTitle: LocalizedStringKey {
        viewModel.location == nil ? "Konum seç" : "Değiştir"
    }

    private func summary(of location: NotificationLocation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(location.name)
                .font(.headline)
            if let address = location.address, !address.isEmpty {
                Text(address)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summaryLabel(of: location))
        .accessibilityIdentifier("notificationComposer.location.summary")
    }

    private func summaryLabel(of location: NotificationLocation) -> String {
        let place = [location.name, location.address].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        return String(localized: "Seçilen konum: \(place)")
    }
}

#if DEBUG
#Preview("Konum satırları") {
    let viewModel = NotificationComposerViewModel(service: MockNotificationAdminService())
    viewModel.actionChoice = .location
    viewModel.location = MockLocationPicker.sampleLocation
    return Form {
        Section("Eylem") {
            NotificationComposerLocationRows(viewModel: viewModel)
        }
    }
    .environment(AppEnvironment.mock())
}
#endif

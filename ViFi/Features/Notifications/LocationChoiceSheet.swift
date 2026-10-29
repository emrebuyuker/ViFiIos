import SwiftUI
import UIKit

extension View {
    /// Offers the two maps apps for `location` ("Konuma Git"): Google Maps or Apple Maps. Shown whenever the
    /// binding holds a location, which the sheet clears again when it goes away.
    func locationChoiceSheet(for binding: Binding<NotificationLocation?>) -> some View {
        sheet(item: binding) { place in
            LocationChoiceView(location: place, onFinish: { binding.wrappedValue = nil })
        }
    }
}

/// What the sheet is keyed on; a place has no id of its own.
nonisolated extension NotificationLocation: Identifiable {
    var id: String { "\(latitude),\(longitude),\(placeId ?? name)" }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The sheet's content: which place, and one button per maps app.
private struct LocationChoiceView: View {
    let location: NotificationLocation
    let onFinish: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var contentHeight: CGFloat = 340

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 4) {
                Text("Konumu hangi uygulamada açmak istersin?")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(placeSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                Button {
                    openGoogleMaps()
                } label: {
                    // Black on the brand orange: white text would fall below 3:1 contrast.
                    Label("Google Haritalar", systemImage: "map")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("inbox.location.google")

                Button {
                    open(MapsLinks.appleMapsURL(for: location))
                } label: {
                    Label("Apple Haritalar", systemImage: "map.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("inbox.location.apple")

                Button("Vazgeç", action: onFinish)
                    .accessibilityIdentifier("inbox.location.cancel")
            }
            .controlSize(.large)
        }
        .padding(.horizontal, 24)
        .padding(.top, 32)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
        })
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        // Sized to its content so the sheet stays snug at every text size (plus room for the home indicator).
        .presentationDetents([.height(contentHeight + 34)])
        .presentationDragIndicator(.visible)
    }

    private var placeSummary: String {
        let address = location.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return address.isEmpty ? location.name : "\(location.name)\n\(address)"
    }

    /// The Google Maps app when it is installed, the web page otherwise (also when the app refuses the link).
    private func openGoogleMaps() {
        let isAppInstalled = MapsLinks.googleMapsAppProbe.map { UIApplication.shared.canOpenURL($0) } ?? false
        guard let url = MapsLinks.googleMapsURL(for: location, isAppInstalled: isAppInstalled) else { return }
        openURL(url) { accepted in
            if !accepted, isAppInstalled { open(MapsLinks.googleMapsWebURL(for: location)) }
        }
        onFinish()
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        openURL(url)
        onFinish()
    }
}

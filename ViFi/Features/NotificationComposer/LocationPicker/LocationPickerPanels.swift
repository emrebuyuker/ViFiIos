import SwiftUI

// The two panels of the location picker that sit over / under the map. They edit the same view model.

// MARK: - Search

/// The place search field and, under it, what it found. Selecting a result moves the map to that place.
struct LocationPickerSearchPanel: View {
    let viewModel: LocationPickerViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            field
            if showsResults {
                Divider()
                results
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
    }

    private var showsResults: Bool {
        viewModel.searchState != .idle || viewModel.resolveError != nil
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(
                "Yer ara",
                text: Binding(get: { viewModel.query }, set: { viewModel.updateQuery($0) })
            )
            .focused($isFocused)
            .submitLabel(.search)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .accessibilityIdentifier("locationPicker.search")
            if !viewModel.query.isEmpty {
                Button {
                    viewModel.updateQuery("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Aramayı temizle")
                .accessibilityIdentifier("locationPicker.search.clear")
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private var results: some View {
        if let message = viewModel.resolveError {
            note(message, systemImage: "exclamationmark.circle.fill", tint: .red)
        } else {
            switch viewModel.searchState {
            case .idle:
                EmptyView()
            case .searching:
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Aranıyor…")
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            case .noResults:
                note(String(localized: "Sonuç bulunamadı."), systemImage: "magnifyingglass", tint: .secondary)
            case let .failed(message):
                note(message, systemImage: "exclamationmark.circle.fill", tint: .red)
            case let .results(suggestions):
                suggestionList(suggestions)
            }
        }
    }

    private func note(_ text: String, systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.subheadline)
            .foregroundStyle(tint)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func suggestionList(_ suggestions: [PlaceSuggestion]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(suggestions) { suggestion in
                    Button {
                        isFocused = false
                        Task { await viewModel.select(suggestion) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title)
                                .font(.body)
                                .foregroundStyle(.primary)
                            if let subtitle = suggestion.subtitle {
                                Text(subtitle)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("locationPicker.suggestion.\(suggestion.id)")
                    Divider()
                }
            }
        }
        .frame(maxHeight: 280)
    }
}

// MARK: - Details

/// The pin's coordinates, the editable name (required) and address (optional), and "Bu konumu seç". A quiet note
/// says when the location permission is off.
struct LocationPickerDetailsCard: View {
    @Bindable var viewModel: LocationPickerViewModel
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(viewModel.coordinateText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel("Koordinat: \(viewModel.coordinateText)")
                .accessibilityIdentifier("locationPicker.coordinates")

            if viewModel.isLocationDenied {
                // A quiet note, not a prompt: the admin chose this, and the picker works without it.
                Label("Konum izni kapalı; harita bulunduğun yere odaklanmaz.", systemImage: "location.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("locationPicker.locationDenied")
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("Yer adı (zorunlu)", text: $viewModel.name)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.words)
                    // Place names are proper nouns that autocorrect would "fix".
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .accessibilityIdentifier("locationPicker.name")
                if viewModel.isNameTooLong {
                    limitNote(String(localized: "Ad en fazla \(NotificationLocation.nameLimit) karakter olabilir."))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("Adres (isteğe bağlı)", text: $viewModel.address)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("locationPicker.address")
                    .overlay(alignment: .trailing) {
                        if viewModel.isLoadingAddress {
                            // The address of a place tapped on the map is on its way.
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 8)
                                .accessibilityLabel("Adres alınıyor")
                                .accessibilityIdentifier("locationPicker.addressLoading")
                        }
                    }
                if viewModel.isAddressTooLong {
                    limitNote(String(localized: "Adres en fazla \(NotificationLocation.addressLimit) karakter olabilir."))
                }
            }

            Button(action: onConfirm) {
                // Black on the brand orange: white text would fall below 3:1 contrast.
                Text("Bu konumu seç")
                    .fontWeight(.semibold)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.canConfirm)
            .accessibilityIdentifier("locationPicker.confirm")
        }
        .padding(16)
        .background(.bar)
    }

    private func limitNote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.red)
    }
}

#if DEBUG
#Preview("Arama ve ayrıntılar") {
    let viewModel = LocationPickerViewModel(initial: nil, searcher: PreviewPlaceSearcher())
    VStack(spacing: 0) {
        LocationPickerSearchPanel(viewModel: viewModel)
            .padding(12)
        Spacer()
        LocationPickerDetailsCard(viewModel: viewModel) {}
    }
    .background(Color.gray.opacity(0.2))
}

/// Canned results for previews, which cannot start the Google SDKs.
private final class PreviewPlaceSearcher: PlaceSearching {
    func suggestions(for query: String, near area: SearchArea?) async throws -> [PlaceSuggestion] {
        [PlaceSuggestion(id: "preview", title: "Kadıköy", subtitle: "İstanbul")]
    }

    func place(for suggestion: PlaceSuggestion) async throws -> PlaceDetails {
        PlaceDetails(placeId: "preview", name: "Kadıköy", address: "Kadıköy, İstanbul", latitude: 40.99, longitude: 29.03)
    }

    func address(ofPlace placeId: String) async throws -> String? {
        "Kadıköy, İstanbul"
    }
}
#endif

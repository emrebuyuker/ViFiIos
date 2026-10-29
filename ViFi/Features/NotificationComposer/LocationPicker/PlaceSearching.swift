import Foundation

/// One line of the place search's suggestion list.
nonisolated struct PlaceSuggestion: Identifiable, Hashable, Sendable {
    /// The Google place id; also what `PlaceSearching.place(for:)` resolves.
    let id: String
    let title: String
    let subtitle: String?
}

/// A place resolved from a suggestion.
nonisolated struct PlaceDetails: Hashable, Sendable {
    let placeId: String
    let name: String
    let address: String?
    let latitude: Double
    let longitude: Double
}

/// Why a place search failed, with a Turkish message for the picker.
nonisolated enum PlaceSearchError: LocalizedError, Equatable {
    /// The service refused or failed the request (an invalid key, a restricted key, quota, the network).
    case unavailable
    /// The suggestion no longer resolves to a place.
    case notFound

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "Arama şu an kullanılamıyor. Haritayı kaydırarak konumu yine de seçebilirsin.")
        case .notFound:
            String(localized: "Bu yer bulunamadı. Başka bir sonuç seç.")
        }
    }
}

/// Searches for places by name (Google Places autocomplete in the app, a stub in tests).
///
/// A search session is what the Places service bills by: the suggestions fetched while typing and the one place
/// fetch that follows belong to one session, which `place(for:)` ends.
protocol PlaceSearching: AnyObject {
    /// Suggestions for what the admin has typed so far.
    func suggestions(for query: String) async throws -> [PlaceSuggestion]
    /// The place behind a suggestion; ends the current search session.
    func place(for suggestion: PlaceSuggestion) async throws -> PlaceDetails
}

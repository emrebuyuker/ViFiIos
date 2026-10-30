import Foundation

/// One line of the place search's suggestion list.
nonisolated struct PlaceSuggestion: Identifiable, Hashable, Sendable {
    /// The Google place id; also what `PlaceSearching.place(for:)` resolves.
    let id: String
    let title: String
    let subtitle: String?
}

/// A circle place searches favor: results inside it rank higher, places elsewhere still come back.
nonisolated struct SearchArea: Equatable, Sendable {
    /// The largest radius, in meters, the Places service accepts for a circle.
    static let maximumRadius: Double = 50_000

    let latitude: Double
    let longitude: Double
    /// In meters, more than 0 and at most `maximumRadius`.
    let radius: Double
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
/// fetch that follows belong to one session, which `place(for:)` (or `address(ofPlace:)`) ends.
protocol PlaceSearching: AnyObject {
    /// Suggestions for what the admin has typed so far, favoring `area` when there is one.
    func suggestions(for query: String, near area: SearchArea?) async throws -> [PlaceSuggestion]
    /// The place behind a suggestion; ends the current search session.
    func place(for suggestion: PlaceSuggestion) async throws -> PlaceDetails
    /// The formatted address of a place tapped on the map (its name and coordinate come with the tap), or `nil`
    /// when it has none; ends the current search session.
    func address(ofPlace placeId: String) async throws -> String?
}

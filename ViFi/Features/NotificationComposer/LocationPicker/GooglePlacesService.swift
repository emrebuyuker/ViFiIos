import CoreLocation
import Foundation
import GooglePlaces
import OSLog

/// `PlaceSearching` on the Google Places SDK (Places API (New)): autocomplete suggestions while typing, then one
/// place fetch, all under one session token so Google bills the whole search as a single session. A place tapped
/// on the map is fetched the same way (its address only), ending the session too.
///
/// `GoogleMapsSDK.startIfPossible()` must have succeeded before this is used.
final class GooglePlacesService: PlaceSearching {
    /// A session lasts a few minutes; renewing earlier keeps a long pause from sending a stale token.
    private static let sessionLifetime: TimeInterval = 150

    private var sessionToken = GMSAutocompleteSessionToken()
    private var sessionStartedAt = Date.now

    func suggestions(for query: String, near area: SearchArea?) async throws -> [PlaceSuggestion] {
        renewSessionIfStale()
        let request = GMSAutocompleteRequest(query: query)
        request.sessionToken = sessionToken
        let filter = GMSAutocompleteFilter()
        // Ranks and formats for Turkey without hiding results elsewhere.
        filter.regionCode = "TR"
        if let area {
            // Ranks what the map is showing first; a bias, so places elsewhere still come back. Not billed extra.
            let center = CLLocationCoordinate2D(latitude: area.latitude, longitude: area.longitude)
            filter.locationBias = GMSPlaceCircularLocationOption(center, area.radius)
        }
        request.filter = filter

        return try await withCheckedThrowingContinuation { continuation in
            GMSPlacesClient.shared().fetchAutocompleteSuggestions(from: request) { suggestions, error in
                if let error {
                    Logger.app.error("Place autocomplete failed: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(throwing: PlaceSearchError.unavailable)
                    return
                }
                let mapped = (suggestions ?? []).compactMap { suggestion -> PlaceSuggestion? in
                    guard let place = suggestion.placeSuggestion else { return nil }
                    return PlaceSuggestion(
                        id: place.placeID,
                        title: place.attributedPrimaryText.string,
                        subtitle: place.attributedSecondaryText?.string
                    )
                }
                continuation.resume(returning: mapped)
            }
        }
    }

    func place(for suggestion: PlaceSuggestion) async throws -> PlaceDetails {
        // Only what the notification needs; every extra field is billed at a higher tier.
        let properties: [GMSPlaceProperty] = [.name, .coordinate, .formattedAddress, .placeID]
        return try await fetchPlace(id: suggestion.id, properties: properties) { place in
            guard CLLocationCoordinate2DIsValid(place.coordinate) else {
                throw PlaceSearchError.notFound
            }
            return PlaceDetails(
                placeId: place.placeID ?? suggestion.id,
                name: place.name ?? suggestion.title,
                address: place.formattedAddress,
                latitude: place.coordinate.latitude,
                longitude: place.coordinate.longitude
            )
        }
    }

    func address(ofPlace placeId: String) async throws -> String? {
        // The tap already gave the name and coordinate; the address alone is the cheapest field set.
        try await fetchPlace(id: placeId, properties: [.formattedAddress]) { $0.formattedAddress }
    }

    // MARK: - Private

    /// Fetches one place under the current session token, then starts a new session: a place fetch ends one.
    private func fetchPlace<Value: Sendable>(
        id: String,
        properties: [GMSPlaceProperty],
        map: @escaping (GMSPlace) throws -> Value
    ) async throws -> Value {
        let request = GMSFetchPlaceRequest(placeID: id, placeProperties: properties.map(\.rawValue), sessionToken: sessionToken)
        let value: Value = try await withCheckedThrowingContinuation { continuation in
            GMSPlacesClient.shared().fetchPlace(with: request) { place, error in
                if let error {
                    Logger.app.error("Place fetch failed: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(throwing: PlaceSearchError.unavailable)
                    return
                }
                guard let place else {
                    continuation.resume(throwing: PlaceSearchError.notFound)
                    return
                }
                continuation.resume(with: Result { try map(place) })
            }
        }
        // The place fetch ends the session; the next search starts a new one.
        startNewSession()
        return value
    }

    private func renewSessionIfStale() {
        if Date.now.timeIntervalSince(sessionStartedAt) > Self.sessionLifetime {
            startNewSession()
        }
    }

    private func startNewSession() {
        sessionToken = GMSAutocompleteSessionToken()
        sessionStartedAt = .now
    }
}

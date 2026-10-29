import CoreLocation
import Foundation
import GooglePlaces
import OSLog

/// `PlaceSearching` on the Google Places SDK (Places API (New)): autocomplete suggestions while typing, then one
/// place fetch, all under one session token so Google bills the whole search as a single session.
///
/// `GoogleMapsSDK.startIfPossible()` must have succeeded before this is used.
final class GooglePlacesService: PlaceSearching {
    /// A session lasts a few minutes; renewing earlier keeps a long pause from sending a stale token.
    private static let sessionLifetime: TimeInterval = 150

    private var sessionToken = GMSAutocompleteSessionToken()
    private var sessionStartedAt = Date.now

    func suggestions(for query: String) async throws -> [PlaceSuggestion] {
        renewSessionIfStale()
        let request = GMSAutocompleteRequest(query: query)
        request.sessionToken = sessionToken
        let filter = GMSAutocompleteFilter()
        // Ranks and formats for Turkey without hiding results elsewhere.
        filter.regionCode = "TR"
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
        let properties = [GMSPlaceProperty.name, .coordinate, .formattedAddress, .placeID].map(\.rawValue)
        let request = GMSFetchPlaceRequest(placeID: suggestion.id, placeProperties: properties, sessionToken: sessionToken)

        let details: PlaceDetails = try await withCheckedThrowingContinuation { continuation in
            GMSPlacesClient.shared().fetchPlace(with: request) { place, error in
                if let error {
                    Logger.app.error("Place fetch failed: \(error.localizedDescription, privacy: .public)")
                    continuation.resume(throwing: PlaceSearchError.unavailable)
                    return
                }
                guard let place, CLLocationCoordinate2DIsValid(place.coordinate) else {
                    continuation.resume(throwing: PlaceSearchError.notFound)
                    return
                }
                continuation.resume(returning: PlaceDetails(
                    placeId: place.placeID ?? suggestion.id,
                    name: place.name ?? suggestion.title,
                    address: place.formattedAddress,
                    latitude: place.coordinate.latitude,
                    longitude: place.coordinate.longitude
                ))
            }
        }
        // The place fetch ends the session; the next search starts a new one.
        startNewSession()
        return details
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

import GoogleMaps
import GooglePlaces

/// Hands the API key to the Google Maps and Places SDKs, once.
///
/// Nothing here runs at launch: the key is provided lazily, right before the admin's location picker first needs
/// a map, so the SDKs never start in mock mode, for regular users, or without a key. Creating a map without a key
/// makes the Maps SDK throw, so callers must check the result and show an "unavailable" state instead.
enum GoogleMapsSDK {
    private static var isStarted = false

    /// Provides the key to both SDKs if it has not been yet. Returns whether they are ready for use; `false` when
    /// the build has no usable key.
    static func startIfPossible(_ configuration: GoogleMapsConfiguration = .current) -> Bool {
        guard let apiKey = configuration.apiKey else { return false }
        if !isStarted {
            GMSServices.provideAPIKey(apiKey)
            GMSPlacesClient.provideAPIKey(apiKey)
            isStarted = true
        }
        return true
    }
}

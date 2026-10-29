import Foundation

/// The Google Maps / Places API key the build was given, or nothing when it was built without one.
///
/// The key is never in the repository: `Config/Secrets.xcconfig` (gitignored) holds `GOOGLE_MAPS_API_KEY`, and
/// `project.yml` exposes it as the Info.plist entry `GMSApiKey`. A checkout without the secrets file still builds;
/// the value is then empty (or, if the xcconfig was not wired in at all, the literal `$(GOOGLE_MAPS_API_KEY)`), and
/// the map features report themselves as unavailable instead of letting the SDK throw.
nonisolated struct GoogleMapsConfiguration: Equatable, Sendable {
    /// The Info.plist key the build setting is exposed under.
    static let infoDictionaryKey = "GMSApiKey"

    /// The usable key, or `nil` when none was configured.
    let apiKey: String?

    /// Reads the key from an Info.plist dictionary (the app bundle's by default).
    init(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) {
        apiKey = Self.usableKey(from: infoDictionary?[Self.infoDictionaryKey])
    }

    var isAvailable: Bool { apiKey != nil }

    /// The configuration of the running app.
    static let current = GoogleMapsConfiguration()

    /// The trimmed key, unless it is missing, blank, or a build-setting reference that was never expanded.
    private static func usableKey(from value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        // "$(GOOGLE_MAPS_API_KEY)" (or "${…}") stays literal when the setting is not defined in any xcconfig.
        if text.hasPrefix("$(") || text.hasPrefix("${") {
            return nil
        }
        return text
    }
}

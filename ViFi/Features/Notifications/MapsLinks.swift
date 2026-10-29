import Foundation

/// The URLs that open a notification's location in a maps app. Pure, so they can be unit-tested.
///
/// Google Maps is tried as an installed app first (`comgooglemaps://`, which needs `comgooglemaps` in the
/// Info.plist's `LSApplicationQueriesSchemes`), and falls back to its web URL, which opens in the browser. Apple
/// Maps is always there.
nonisolated enum MapsLinks {
    /// The URL scheme of the Google Maps app; also what `canOpenURL` is asked about.
    static let googleMapsAppScheme = "comgooglemaps"
    private static let googleMapsAppZoom = 16

    /// Whether the Google Maps app can be opened; used to probe with `UIApplication.canOpenURL`.
    static var googleMapsAppProbe: URL? {
        URL(string: "\(googleMapsAppScheme)://")
    }

    /// The Google Maps app: a pin at the place, centered at zoom 16.
    static func googleMapsAppURL(for location: NotificationLocation) -> URL? {
        let point = coordinates(of: location)
        return URL(string: "\(googleMapsAppScheme)://?q=\(point)&center=\(point)&zoom=\(googleMapsAppZoom)")
    }

    /// Google Maps on the web; `placeId` pins the exact Google place when the location came from a search result.
    static func googleMapsWebURL(for location: NotificationLocation) -> URL? {
        var query = "api=1&query=\(decimal(location.latitude))%2C\(decimal(location.longitude))"
        if let placeId = location.placeId?.trimmingCharacters(in: .whitespacesAndNewlines), !placeId.isEmpty {
            query += "&query_place_id=\(percentEncoded(placeId))"
        }
        return URL(string: "https://www.google.com/maps/search/?\(query)")
    }

    /// The URL to open for "Google Haritalar": the app when it is installed, the web page otherwise.
    static func googleMapsURL(for location: NotificationLocation, isAppInstalled: Bool) -> URL? {
        isAppInstalled ? googleMapsAppURL(for: location) : googleMapsWebURL(for: location)
    }

    /// Apple Maps, labelled with the place's name.
    static func appleMapsURL(for location: NotificationLocation) -> URL? {
        let name = location.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var query = "ll=\(coordinates(of: location))"
        if !name.isEmpty {
            query += "&q=\(percentEncoded(name))"
        }
        return URL(string: "https://maps.apple.com/?\(query)")
    }

    // MARK: - Private

    /// `"<lat>,<lng>"` as plain decimal numbers, whatever the device's region (no grouping, a dot for decimals).
    private static func coordinates(of location: NotificationLocation) -> String {
        "\(decimal(location.latitude)),\(decimal(location.longitude))"
    }

    /// Six decimals (about 10 cm) without trailing zeros; `String(format:)` does not follow the user's locale.
    private static func decimal(_ value: Double) -> String {
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text == "-0" ? "0" : text
    }

    /// Everything but unreserved characters is escaped, so a name with `&`, `+` or `#` cannot break the query.
    private static func percentEncoded(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}

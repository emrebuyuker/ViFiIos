import Foundation
import Testing
@testable import ViFi

@Suite("MapsLinks")
struct MapsLinksTests {
    private let cafe = NotificationLocation(
        latitude: 40.9903,
        longitude: 29.029,
        name: "ViFi Öğrenci Kafesi",
        address: "Caferağa, Kadıköy",
        placeId: nil
    )

    // MARK: Google Maps app

    @Test("The Google Maps app link pins the place and centers on it at zoom 16")
    func googleMapsApp() {
        #expect(MapsLinks.googleMapsAppURL(for: cafe)?.absoluteString
            == "comgooglemaps://?q=40.9903,29.029&center=40.9903,29.029&zoom=16")
    }

    @Test("The app is probed by its bare scheme")
    func probe() {
        #expect(MapsLinks.googleMapsAppProbe?.absoluteString == "comgooglemaps://")
    }

    // MARK: Google Maps web

    @Test("The web link searches the coordinate")
    func googleMapsWeb() {
        #expect(MapsLinks.googleMapsWebURL(for: cafe)?.absoluteString
            == "https://www.google.com/maps/search/?api=1&query=40.9903%2C29.029")
    }

    @Test("A Google place id is added when the location came from a search result")
    func googleMapsWebWithPlaceId() {
        let place = NotificationLocation(
            latitude: 41.0082, longitude: 28.9784, name: "Ayasofya", address: nil, placeId: "ChIJ9z1-abc_DEF"
        )

        #expect(MapsLinks.googleMapsWebURL(for: place)?.absoluteString
            == "https://www.google.com/maps/search/?api=1&query=41.0082%2C28.9784&query_place_id=ChIJ9z1-abc_DEF")
    }

    @Test("A blank place id is left out and an odd one is escaped")
    func placeIdEdgeCases() {
        let blank = NotificationLocation(latitude: 1, longitude: 2, name: "A", address: nil, placeId: "  ")
        #expect(MapsLinks.googleMapsWebURL(for: blank)?.absoluteString == "https://www.google.com/maps/search/?api=1&query=1%2C2")

        let odd = NotificationLocation(latitude: 1, longitude: 2, name: "A", address: nil, placeId: "a&b=c d")
        #expect(MapsLinks.googleMapsWebURL(for: odd)?.absoluteString
            == "https://www.google.com/maps/search/?api=1&query=1%2C2&query_place_id=a%26b%3Dc%20d")
    }

    @Test("Google Haritalar opens the app when it is installed and the web page otherwise")
    func googleChoice() {
        #expect(MapsLinks.googleMapsURL(for: cafe, isAppInstalled: true) == MapsLinks.googleMapsAppURL(for: cafe))
        #expect(MapsLinks.googleMapsURL(for: cafe, isAppInstalled: false) == MapsLinks.googleMapsWebURL(for: cafe))
        #expect(MapsLinks.googleMapsURL(for: cafe, isAppInstalled: false)?.scheme == "https")
    }

    // MARK: Apple Maps

    @Test("The Apple Maps link carries the coordinate and the escaped name")
    func appleMaps() {
        #expect(MapsLinks.appleMapsURL(for: cafe)?.absoluteString
            == "https://maps.apple.com/?ll=40.9903,29.029&q=ViFi%20%C3%96%C4%9Frenci%20Kafesi")
    }

    @Test("Characters that would break a query are escaped in the name")
    func appleMapsEscaping() {
        let place = NotificationLocation(latitude: 1, longitude: 2, name: "Çay & Kahve +%20#1", address: nil, placeId: nil)

        let url = MapsLinks.appleMapsURL(for: place)
        #expect(url?.absoluteString == "https://maps.apple.com/?ll=1,2&q=%C3%87ay%20%26%20Kahve%20%2B%2520%231")
        // Round-trips to the original name.
        let items = URLComponents(url: url ?? URL(filePath: "/"), resolvingAgainstBaseURL: false)?.queryItems
        #expect(items?.first { $0.name == "q" }?.value == "Çay & Kahve +%20#1")
    }

    // MARK: Numbers

    @Test("Coordinates are plain decimals: negative, whole, tiny and long ones")
    func numbers() {
        let spot = NotificationLocation(latitude: -33.8688, longitude: 151, name: "Sidney", address: nil, placeId: nil)
        #expect(MapsLinks.googleMapsAppURL(for: spot)?.absoluteString
            == "comgooglemaps://?q=-33.8688,151&center=-33.8688,151&zoom=16")

        let origin = NotificationLocation(latitude: 0, longitude: -0.0000001, name: "Sıfır", address: nil, placeId: nil)
        #expect(MapsLinks.googleMapsWebURL(for: origin)?.absoluteString == "https://www.google.com/maps/search/?api=1&query=0%2C0")

        let long = NotificationLocation(latitude: 41.015137123456, longitude: 28.97953, name: "Uzun", address: nil, placeId: nil)
        #expect(MapsLinks.googleMapsWebURL(for: long)?.absoluteString
            == "https://www.google.com/maps/search/?api=1&query=41.015137%2C28.97953")

        let tiny = NotificationLocation(latitude: 0.00001, longitude: 1, name: "Küçük", address: nil, placeId: nil)
        #expect(MapsLinks.googleMapsWebURL(for: tiny)?.absoluteString == "https://www.google.com/maps/search/?api=1&query=0.00001%2C1")
    }
}

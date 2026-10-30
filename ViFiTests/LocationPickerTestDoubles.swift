import Foundation
@testable import ViFi

/// A `PlaceSearching` with scripted answers that records every call.
@MainActor
final class StubPlaceSearcher: PlaceSearching {
    var suggestionsResult: Result<[PlaceSuggestion], any Error> = .success([])
    var placeResult: Result<PlaceDetails, any Error> = .success(LocationPickerFixture.kadikoy)
    /// Addresses of places tapped on the map, by place id; an id not listed has no address.
    var addresses: [String: Result<String?, any Error>] = [:]
    /// When set, every place fetch for a suggestion waits at the gate before it is answered.
    var placeGate: AsyncGate?
    /// When set, every address lookup waits at the gate before it is answered.
    var addressGate: AsyncGate?

    private(set) var queries: [String] = []
    /// The area each search favored, in order.
    private(set) var areas: [SearchArea?] = []
    private(set) var resolved: [PlaceSuggestion] = []
    private(set) var addressLookups: [String] = []

    func suggestions(for query: String, near area: SearchArea?) async throws -> [PlaceSuggestion] {
        queries.append(query)
        areas.append(area)
        return try suggestionsResult.get()
    }

    func place(for suggestion: PlaceSuggestion) async throws -> PlaceDetails {
        resolved.append(suggestion)
        await placeGate?.pass()
        return try placeResult.get()
    }

    func address(ofPlace placeId: String) async throws -> String? {
        addressLookups.append(placeId)
        await addressGate?.pass()
        return try (addresses[placeId] ?? .success(nil)).get()
    }
}

/// A `DeviceLocating` with a scripted permission answer and fix that records every call.
@MainActor
final class StubDeviceLocator: DeviceLocating {
    private(set) var authorization: LocationAuthorization
    /// What the admin answers when asked.
    var answer: LocationAuthorization
    var fix: DeviceCoordinate?
    /// When set, the permission prompt stays up at the gate until the test opens it.
    var promptGate: AsyncGate?
    /// When set, the fix waits at the gate until the test opens it.
    var fixGate: AsyncGate?

    private(set) var requestCount = 0
    private(set) var locateCount = 0

    init(
        authorization: LocationAuthorization = .authorized,
        answer: LocationAuthorization = .authorized,
        fix: DeviceCoordinate? = LocationPickerFixture.here
    ) {
        self.authorization = authorization
        self.answer = answer
        self.fix = fix
    }

    func requestAuthorization() async -> LocationAuthorization {
        requestCount += 1
        guard authorization == .notDetermined else { return authorization }
        await promptGate?.pass()
        authorization = answer
        return answer
    }

    func currentLocation() async -> DeviceCoordinate? {
        locateCount += 1
        await fixGate?.pass()
        return fix
    }
}

enum LocationPickerFixture {
    static let suggestion = PlaceSuggestion(id: "place-1", title: "Kadıköy", subtitle: "İstanbul")
    static let kadikoy = PlaceDetails(
        placeId: "place-1",
        name: "Kadıköy",
        address: "Caferağa, Kadıköy/İstanbul",
        latitude: 40.9903,
        longitude: 29.029
    )
    /// A precise fix of the device, in Beşiktaş.
    static let here = DeviceCoordinate(latitude: 41.0422, longitude: 29.0083, accuracy: 12)
    /// A place label on the map.
    static let pastane = (placeId: "poi-1", name: "A Pastanesi", latitude: 41.0431, longitude: 29.0071)
    static let pastaneAddress = "Sinanpaşa, Beşiktaş/İstanbul"
}

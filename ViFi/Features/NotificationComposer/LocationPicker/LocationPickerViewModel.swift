import Foundation
import Observation

/// Where the map is looking: the first camera, and the moves the picker asks the map for (a chosen search result).
nonisolated struct MapCamera: Equatable, Sendable {
    let latitude: Double
    let longitude: Double
    let zoom: Float
}

/// A request to move the map. The `id` makes two moves to the same spot distinct, so the map acts on each.
nonisolated struct CameraRequest: Equatable, Sendable {
    let id: Int
    let camera: MapCamera
}

/// Drives the admin's location picker: a map with a fixed center pin (the coordinate is wherever the map is
/// centered), a place search that moves the map to the chosen result, and the name and address the notification
/// shows. Ends in a `NotificationLocation`, only when it is valid.
@Observable
final class LocationPickerViewModel {
    /// What the search box is showing under the field.
    enum SearchState: Equatable {
        case idle
        case searching
        case results([PlaceSuggestion])
        case noResults
        case failed(message: String)
    }

    /// Fewer characters than this are not searched: each search is a billable Places request.
    static let minimumQueryLength = 3
    /// The zoom of a map that was just moved to a place (street level).
    static let placeZoom: Float = 16
    /// Roughly Turkey as a whole: where an empty picker starts, before the admin searches or pans.
    static let defaultCamera = MapCamera(latitude: 39.0, longitude: 35.2, zoom: 5)
    /// About a meter. A map dragged further than this is no longer on the place that was picked.
    private static let placeTolerance = 0.00001

    // MARK: State

    /// The text in the search box; changed through `updateQuery(_:)`.
    private(set) var query = ""
    private(set) var searchState: SearchState = .idle
    /// Whether a chosen suggestion is being resolved to a place.
    private(set) var isResolving = false
    /// Why the chosen suggestion could not be used.
    private(set) var resolveError: String?
    /// The latest move the map was asked to make; `nil` until a search result is chosen.
    private(set) var cameraRequest: CameraRequest?

    var name: String
    var address: String

    /// The center of the map, where the pin is.
    private(set) var latitude: Double
    private(set) var longitude: Double
    /// The Google place the pin is on, while it is still on it.
    private(set) var placeId: String?

    /// Where the map starts.
    let initialCamera: MapCamera

    @ObservationIgnored private let searcher: any PlaceSearching
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var cameraRequestCount = 0
    /// Where the picked place is, to tell when the map has been moved away from it.
    @ObservationIgnored private var placeCoordinate: (latitude: Double, longitude: Double)?

    /// - Parameters:
    ///   - initial: The location being changed, if any; the map starts on it.
    ///   - debounce: How long typing must pause before the search is sent.
    init(initial: NotificationLocation? = nil, searcher: any PlaceSearching, debounce: Duration = .milliseconds(350)) {
        self.searcher = searcher
        self.debounce = debounce
        if let initial {
            latitude = initial.latitude
            longitude = initial.longitude
            name = initial.name
            address = initial.address ?? ""
            placeId = initial.placeId
            placeCoordinate = initial.placeId == nil ? nil : (initial.latitude, initial.longitude)
            initialCamera = MapCamera(latitude: initial.latitude, longitude: initial.longitude, zoom: Self.placeZoom)
        } else {
            latitude = Self.defaultCamera.latitude
            longitude = Self.defaultCamera.longitude
            name = ""
            address = ""
            initialCamera = Self.defaultCamera
        }
    }

    // MARK: - Search

    /// Sends the search once typing has paused. Each keystroke restarts the wait, so a word costs one request.
    func updateQuery(_ text: String) {
        query = text
        searchTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minimumQueryLength else {
            searchTask = nil
            searchState = .idle
            return
        }
        searchState = .searching
        searchTask = Task { [debounce] in
            do {
                try await Task.sleep(for: debounce)
            } catch {
                return
            }
            await search(for: trimmed)
        }
    }

    /// Waits for the search in flight; for tests.
    func finishSearch() async {
        await searchTask?.value
    }

    /// Puts the pin on a search result: fetches the place and moves the map to it, with its name and address.
    func select(_ suggestion: PlaceSuggestion) async {
        guard !isResolving else { return }
        isResolving = true
        resolveError = nil
        defer { isResolving = false }
        do {
            let place = try await searcher.place(for: suggestion)
            apply(place)
        } catch is CancellationError {
            // The picker went away; nothing to report.
        } catch {
            resolveError = error.userMessage
        }
    }

    // MARK: - Map

    /// The map came to rest centered on `latitude`/`longitude` (a drag, or the move to a chosen place).
    func mapDidSettle(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
        // The place id describes the place that was picked, not wherever the pin is dragged to afterwards.
        if let placeCoordinate, !isNear(placeCoordinate, latitude: latitude, longitude: longitude) {
            placeId = nil
            self.placeCoordinate = nil
        }
    }

    // MARK: - Result

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedAddress: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isNameTooLong: Bool { trimmedName.count > NotificationLocation.nameLimit }
    var isAddressTooLong: Bool { trimmedAddress.count > NotificationLocation.addressLimit }

    /// The chosen place, or `nil` while something is missing (a name) or over its limit.
    var location: NotificationLocation? {
        let location = NotificationLocation(
            latitude: latitude,
            longitude: longitude,
            name: trimmedName,
            address: trimmedAddress.isEmpty ? nil : trimmedAddress,
            placeId: placeId
        )
        return location.isValid ? location : nil
    }

    var canConfirm: Bool { location != nil && !isResolving }

    /// "41.01514, 28.97953": the pin's coordinates, shown so the admin can see what will be sent.
    var coordinateText: String {
        String(format: "%.5f, %.5f", latitude, longitude)
    }

    // MARK: - Private

    private func search(for query: String) async {
        do {
            let suggestions = try await searcher.suggestions(for: query)
            // A newer search (or a cleared box) supersedes this answer.
            guard !Task.isCancelled else { return }
            searchState = suggestions.isEmpty ? .noResults : .results(suggestions)
        } catch is CancellationError {
            // Superseded by a newer search.
        } catch {
            guard !Task.isCancelled else { return }
            searchState = .failed(message: error.userMessage)
        }
    }

    private func apply(_ place: PlaceDetails) {
        latitude = place.latitude
        longitude = place.longitude
        placeId = place.placeId
        placeCoordinate = (place.latitude, place.longitude)
        name = String(place.name.prefix(NotificationLocation.nameLimit))
        address = String((place.address ?? "").prefix(NotificationLocation.addressLimit))
        // The search is over: close the list and empty the box.
        searchTask?.cancel()
        searchTask = nil
        query = ""
        searchState = .idle
        cameraRequestCount += 1
        cameraRequest = CameraRequest(
            id: cameraRequestCount,
            camera: MapCamera(latitude: place.latitude, longitude: place.longitude, zoom: Self.placeZoom)
        )
    }

    private func isNear(_ place: (latitude: Double, longitude: Double), latitude: Double, longitude: Double) -> Bool {
        abs(place.latitude - latitude) <= Self.placeTolerance && abs(place.longitude - longitude) <= Self.placeTolerance
    }
}

import Foundation
import Observation

/// Where the map is looking: the first camera, and the moves the picker asks the map for (a chosen search result,
/// a tapped place, the device's location).
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
/// centered), a place search that moves the map to the chosen result, places on the map that can be tapped, and the
/// name and address the notification shows. Ends in a `NotificationLocation`, only when it is valid.
///
/// With a `DeviceLocating`, the picker also asks for the location permission once and opens on the device's
/// location, unless the admin has already put the map somewhere (see `locateDevice()`).
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
    /// The zoom for an approximate device location (Precise Location off): the district, not a wrong street.
    static let approximateZoom: Float = 12
    /// A fix less certain than this many meters is approximate.
    static let preciseAccuracy: Double = 1_000
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
    /// The latest move the map was asked to make; `nil` until there is somewhere to go.
    private(set) var cameraRequest: CameraRequest?
    /// Whether the address of a place tapped on the map is still being looked up.
    private(set) var isLoadingAddress = false
    /// The location permission once the picker has checked it; `nil` before that and without a locator.
    private(set) var locationAuthorization: LocationAuthorization?

    var name: String
    var address: String

    /// The center of the map, where the pin is.
    private(set) var latitude: Double
    private(set) var longitude: Double
    /// The Google place the pin is on, while it is still on it.
    private(set) var placeId: String?
    /// Where searches rank results first: what the map shows, once it is zoomed in far enough.
    @ObservationIgnored private(set) var searchArea: SearchArea?

    /// Where the map starts.
    let initialCamera: MapCamera

    @ObservationIgnored private let searcher: any PlaceSearching
    @ObservationIgnored private let locator: (any DeviceLocating)?
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var addressTask: Task<Void, Never>?
    @ObservationIgnored private var cameraRequestCount = 0
    /// Bumped by every chosen place (a search result or a tap on the map), so an answer for an older one is dropped.
    @ObservationIgnored private var selectionCount = 0
    /// Where the picked place is, to tell when the map has been moved away from it.
    @ObservationIgnored private var placeCoordinate: (latitude: Double, longitude: Double)?
    /// The zoom the map last came to rest at.
    @ObservationIgnored private var zoom: Float
    /// Set once the map is where the admin wants it: the location being changed, a drag or pinch, a chosen search
    /// result or a tapped place. The device's location then no longer moves the map.
    @ObservationIgnored private var isPlacedByAdmin: Bool
    @ObservationIgnored private var hasStartedLocating = false

    /// - Parameters:
    ///   - initial: The location being changed, if any; the map starts (and stays) on it.
    ///   - locator: The device's location; `nil` (previews, tests of other parts) leaves CoreLocation alone.
    ///   - debounce: How long typing must pause before the search is sent.
    init(
        initial: NotificationLocation? = nil,
        searcher: any PlaceSearching,
        locator: (any DeviceLocating)? = nil,
        debounce: Duration = .milliseconds(350)
    ) {
        self.searcher = searcher
        self.locator = locator
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
        zoom = initialCamera.zoom
        isPlacedByAdmin = initial != nil
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
        let selection = selectionCount
        do {
            let place = try await searcher.place(for: suggestion)
            // A place tapped on the map while this one resolved is the newer choice.
            guard selection == selectionCount else { return }
            commitPlace(
                placeId: place.placeId,
                name: place.name,
                address: place.address ?? "",
                at: MapCamera(latitude: place.latitude, longitude: place.longitude, zoom: Self.placeZoom)
            )
        } catch is CancellationError {
            // The picker went away; nothing to report.
        } catch {
            resolveError = error.userMessage
        }
    }

    // MARK: - Map

    /// The map came to rest centered on `latitude`/`longitude` (a drag, or a move the picker asked for).
    /// - Parameters:
    ///   - zoom: The map's zoom, if known.
    ///   - visibleRadius: Meters from the center to the corners of what the map shows, if known; searches favor
    ///     that area while it is small enough for the Places service.
    func mapDidSettle(latitude: Double, longitude: Double, zoom: Float? = nil, visibleRadius: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        // The place id describes the place that was picked, not wherever the pin is dragged to afterwards.
        if let placeCoordinate, !isNear(placeCoordinate, latitude: latitude, longitude: longitude) {
            placeId = nil
            self.placeCoordinate = nil
        }
        if let zoom {
            self.zoom = zoom
        }
        if let visibleRadius {
            // A country-wide view is no "area"; searches then rank for Turkey only, as before.
            let isUsable = visibleRadius > 0 && visibleRadius <= SearchArea.maximumRadius
            searchArea = isUsable ? SearchArea(latitude: latitude, longitude: longitude, radius: visibleRadius) : nil
        }
    }

    /// The admin started dragging or pinching the map: from now on it stays where they take it.
    func mapWillMoveByGesture() {
        isPlacedByAdmin = true
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
            let suggestions = try await searcher.suggestions(for: query, near: searchArea)
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

    /// Puts the pin on a chosen place (a search result or a place tapped on the map) and moves the map there.
    /// Supersedes any earlier choice, including an address still being looked up for it.
    private func commitPlace(placeId: String, name: String, address: String, at camera: MapCamera) {
        selectionCount += 1
        isPlacedByAdmin = true
        addressTask?.cancel()
        addressTask = nil
        isLoadingAddress = false

        latitude = camera.latitude
        longitude = camera.longitude
        self.placeId = placeId
        placeCoordinate = (camera.latitude, camera.longitude)
        self.name = String(name.prefix(NotificationLocation.nameLimit))
        self.address = String(address.prefix(NotificationLocation.addressLimit))
        // The search is over: close the list and empty the box.
        searchTask?.cancel()
        searchTask = nil
        query = ""
        searchState = .idle
        resolveError = nil
        moveCamera(to: camera)
    }

    private func moveCamera(to camera: MapCamera) {
        cameraRequestCount += 1
        cameraRequest = CameraRequest(id: cameraRequestCount, camera: camera)
    }

    private func isNear(_ place: (latitude: Double, longitude: Double), latitude: Double, longitude: Double) -> Bool {
        abs(place.latitude - latitude) <= Self.placeTolerance && abs(place.longitude - longitude) <= Self.placeTolerance
    }
}

// MARK: - Places on the map

extension LocationPickerViewModel {
    /// Puts the pin on a place the admin tapped on the map (a shop or landmark label): its name, coordinate and
    /// place id at once, its address when the lookup answers. The place stays chosen if the lookup fails, and an
    /// address the admin typed meanwhile is kept. Dragging away afterwards behaves as after a search result: the
    /// place id is dropped, the name and address stay as editable text.
    func selectMapPlace(placeId: String, name: String, latitude: Double, longitude: Double) {
        // Close enough to read the label means close enough already: only zoom in, never out.
        let camera = MapCamera(latitude: latitude, longitude: longitude, zoom: max(zoom, Self.placeZoom))
        commitPlace(placeId: placeId, name: Self.singleLine(name), address: "", at: camera)
        isLoadingAddress = true
        let selection = selectionCount
        addressTask = Task {
            await lookUpAddress(ofPlace: placeId, selection: selection)
        }
    }

    /// Waits for the address lookup in flight; for tests.
    func finishAddressLookup() async {
        await addressTask?.value
    }

    private func lookUpAddress(ofPlace placeId: String, selection: Int) async {
        let found: String?
        do {
            found = try await searcher.address(ofPlace: placeId)
        } catch {
            // The address is optional: the place stays chosen without one (the service logged why).
            found = nil
        }
        // A newer choice owns the fields now.
        guard selection == selectionCount else { return }
        isLoadingAddress = false
        guard let found, trimmedAddress.isEmpty else { return }
        address = String(found.prefix(NotificationLocation.addressLimit))
    }

    /// Map labels can break over lines ("A Pastanesi\nKadıköy"); the notification shows one.
    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

// MARK: - Device location

extension LocationPickerViewModel {
    /// Whether the map shows the device's location (its dot and the button that re-centers on it).
    var showsDeviceLocation: Bool { locationAuthorization == .authorized }

    /// Whether the admin turned the location permission off; the picker then only says so, quietly.
    var isLocationDenied: Bool { locationAuthorization == .denied }

    /// Asks for the location permission if it was never asked, then centers the map on the device's first fix,
    /// unless the map is already where the admin wants it: changing an existing location, or a drag, pinch,
    /// chosen search result or tapped place before the fix arrives. Without permission the picker works as
    /// before, without asking again. Runs once per picker; without a locator it does nothing.
    func locateDevice() async {
        guard let locator, !hasStartedLocating else { return }
        hasStartedLocating = true
        var authorization = locator.authorization
        if authorization == .notDetermined {
            authorization = await locator.requestAuthorization()
        }
        locationAuthorization = authorization
        // Changing a location (or one placed during the prompt) needs no fix at all.
        guard authorization == .authorized, followsDevice else { return }
        guard let fix = await locator.currentLocation(), followsDevice else { return }
        let zoom = fix.accuracy > Self.preciseAccuracy ? Self.approximateZoom : Self.placeZoom
        moveCamera(to: MapCamera(latitude: fix.latitude, longitude: fix.longitude, zoom: zoom))
    }

    /// Whether the device's location may still move the map.
    private var followsDevice: Bool { !isPlacedByAdmin && !isResolving }
}

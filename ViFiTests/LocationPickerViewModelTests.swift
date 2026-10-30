import Foundation
import Testing
@testable import ViFi

@MainActor
@Suite("LocationPickerViewModel")
struct LocationPickerViewModelTests {
    private func makeViewModel(
        initial: NotificationLocation? = nil,
        searcher: StubPlaceSearcher = StubPlaceSearcher(),
        debounce: Duration = .zero
    ) -> (LocationPickerViewModel, StubPlaceSearcher) {
        (LocationPickerViewModel(initial: initial, searcher: searcher, debounce: debounce), searcher)
    }

    // MARK: Start

    @Test("An empty picker starts on Turkey with nothing to confirm")
    func emptyStart() {
        let (viewModel, _) = makeViewModel()

        #expect(viewModel.initialCamera == LocationPickerViewModel.defaultCamera)
        #expect(viewModel.location == nil)
        #expect(!viewModel.canConfirm)
        #expect(viewModel.cameraRequest == nil)
    }

    @Test("Changing a location starts on it, with its name and address")
    func startsOnInitial() {
        let initial = NotificationLocation(latitude: 38.5, longitude: 27.1, name: "Kafe", address: "Bornova", placeId: "p1")
        let (viewModel, _) = makeViewModel(initial: initial)

        #expect(viewModel.initialCamera == MapCamera(latitude: 38.5, longitude: 27.1, zoom: LocationPickerViewModel.placeZoom))
        #expect(viewModel.name == "Kafe")
        #expect(viewModel.address == "Bornova")
        #expect(viewModel.location == initial)
        #expect(viewModel.canConfirm)
    }

    // MARK: Search

    @Test("Short queries are not searched")
    func shortQuery() async {
        let (viewModel, searcher) = makeViewModel()

        viewModel.updateQuery("ka")
        await viewModel.finishSearch()

        #expect(searcher.queries.isEmpty)
        #expect(viewModel.searchState == .idle)
        #expect(viewModel.query == "ka")
    }

    @Test("A query is searched after the pause and its results shown")
    func searchShowsResults() async {
        let (viewModel, searcher) = makeViewModel()
        searcher.suggestionsResult = .success([LocationPickerFixture.suggestion])

        viewModel.updateQuery("  Kadıköy ")
        #expect(viewModel.searchState == .searching)
        await viewModel.finishSearch()

        #expect(searcher.queries == ["Kadıköy"], "The query is trimmed")
        #expect(viewModel.searchState == .results([LocationPickerFixture.suggestion]))
    }

    @Test("Typing quickly sends one search, for the latest text")
    func debounced() async {
        let (viewModel, searcher) = makeViewModel(debounce: .milliseconds(50))

        viewModel.updateQuery("kad")
        viewModel.updateQuery("kadı")
        viewModel.updateQuery("kadıköy")
        await viewModel.finishSearch()

        #expect(searcher.queries == ["kadıköy"])
    }

    @Test("No suggestions is its own state")
    func noResults() async {
        let (viewModel, _) = makeViewModel()

        viewModel.updateQuery("xyzxyz")
        await viewModel.finishSearch()

        #expect(viewModel.searchState == .noResults)
    }

    @Test("A failed search reports the reason and keeps the pin usable")
    func searchFailure() async {
        let (viewModel, searcher) = makeViewModel()
        searcher.suggestionsResult = .failure(PlaceSearchError.unavailable)

        viewModel.updateQuery("Kadıköy")
        await viewModel.finishSearch()

        #expect(viewModel.searchState == .failed(message: PlaceSearchError.unavailable.userMessage))
        viewModel.name = "Elle seçilen yer"
        #expect(viewModel.canConfirm, "The pin can still be placed without the search")
    }

    @Test("Clearing the box clears the results and drops a pending search")
    func clearing() async {
        let (viewModel, searcher) = makeViewModel(debounce: .milliseconds(50))
        viewModel.updateQuery("Kadıköy")

        viewModel.updateQuery("")
        await viewModel.finishSearch()

        #expect(searcher.queries.isEmpty)
        #expect(viewModel.searchState == .idle)
    }

    // MARK: Choosing a result

    @Test("Choosing a result moves the map there and fills the name, address and place id")
    func selecting() async throws {
        let (viewModel, searcher) = makeViewModel()
        searcher.suggestionsResult = .success([LocationPickerFixture.suggestion])
        viewModel.updateQuery("Kadıköy")
        await viewModel.finishSearch()

        await viewModel.select(LocationPickerFixture.suggestion)

        #expect(searcher.resolved == [LocationPickerFixture.suggestion])
        #expect(viewModel.name == "Kadıköy")
        #expect(viewModel.address == "Caferağa, Kadıköy/İstanbul")
        #expect(viewModel.placeId == "place-1")
        #expect(viewModel.latitude == 40.9903)
        #expect(viewModel.longitude == 29.029)
        let request = try #require(viewModel.cameraRequest)
        #expect(request.camera == MapCamera(latitude: 40.9903, longitude: 29.029, zoom: LocationPickerViewModel.placeZoom))
        // The search is finished: box and list are empty again.
        #expect(viewModel.query.isEmpty)
        #expect(viewModel.searchState == .idle)
        #expect(!viewModel.isResolving)
        #expect(viewModel.location == NotificationLocation(
            latitude: 40.9903, longitude: 29.029, name: "Kadıköy", address: "Caferağa, Kadıköy/İstanbul", placeId: "place-1"
        ))
    }

    @Test("Each chosen result is a new camera request, even to the same spot")
    func requestsAreDistinct() async throws {
        let (viewModel, _) = makeViewModel()

        await viewModel.select(LocationPickerFixture.suggestion)
        let first = try #require(viewModel.cameraRequest)
        await viewModel.select(LocationPickerFixture.suggestion)
        let second = try #require(viewModel.cameraRequest)

        #expect(first.camera == second.camera)
        #expect(first.id != second.id)
    }

    @Test("A result that cannot be resolved is reported and leaves the pin alone")
    func resolveFailure() async {
        let (viewModel, searcher) = makeViewModel()
        searcher.placeResult = .failure(PlaceSearchError.notFound)

        await viewModel.select(LocationPickerFixture.suggestion)

        #expect(viewModel.resolveError == PlaceSearchError.notFound.userMessage)
        #expect(viewModel.cameraRequest == nil)
        #expect(viewModel.name.isEmpty)
        #expect(!viewModel.isResolving)
    }

    @Test("A very long place name is cut to the limit instead of blocking the notification")
    func longPlaceName() async {
        let (viewModel, searcher) = makeViewModel()
        searcher.placeResult = .success(PlaceDetails(
            placeId: "p",
            name: String(repeating: "a", count: NotificationLocation.nameLimit + 30),
            address: String(repeating: "b", count: NotificationLocation.addressLimit + 30),
            latitude: 1,
            longitude: 2
        ))

        await viewModel.select(LocationPickerFixture.suggestion)

        #expect(viewModel.name.count == NotificationLocation.nameLimit)
        #expect(viewModel.address.count == NotificationLocation.addressLimit)
        #expect(viewModel.canConfirm)
    }

    // MARK: The map

    @Test("The coordinate is wherever the map comes to rest")
    func mapSettles() {
        let (viewModel, _) = makeViewModel()

        viewModel.mapDidSettle(latitude: 41.5, longitude: 28.5)

        #expect(viewModel.latitude == 41.5)
        #expect(viewModel.longitude == 28.5)
        #expect(viewModel.coordinateText == "41.50000, 28.50000")
    }

    @Test("The place id survives the map settling on the place and is dropped once the pin is moved off it")
    func placeIdFollowsThePin() async {
        let (viewModel, _) = makeViewModel()
        await viewModel.select(LocationPickerFixture.suggestion)

        // The animation to the chosen place ends (a hair off is still the place).
        viewModel.mapDidSettle(latitude: 40.9903000001, longitude: 29.0290000001)
        #expect(viewModel.placeId == "place-1")

        // The admin drags the map elsewhere: that is no longer the Google place.
        viewModel.mapDidSettle(latitude: 40.9950, longitude: 29.0350)
        #expect(viewModel.placeId == nil)
        #expect(viewModel.location?.placeId == nil)
        #expect(viewModel.name == "Kadıköy", "The name stays editable text, not tied to the place")

        // Back on the old spot by hand: it was not re-picked, so it stays a plain coordinate.
        viewModel.mapDidSettle(latitude: 40.9903, longitude: 29.029)
        #expect(viewModel.placeId == nil)
    }

    // MARK: Result

    @Test("A name is required, and trimmed")
    func nameRequired() {
        let (viewModel, _) = makeViewModel()
        viewModel.mapDidSettle(latitude: 41, longitude: 29)

        #expect(viewModel.location == nil)

        viewModel.name = "   "
        #expect(!viewModel.canConfirm)

        viewModel.name = "  Kafe  "
        #expect(viewModel.location?.name == "Kafe")
        #expect(viewModel.canConfirm)
    }

    @Test("An empty address is left out")
    func optionalAddress() {
        let (viewModel, _) = makeViewModel()
        viewModel.name = "Kafe"

        viewModel.address = "   "
        #expect(viewModel.location?.address == nil)

        viewModel.address = " Bornova "
        #expect(viewModel.location?.address == "Bornova")
    }

    @Test("A name or address over its limit blocks confirming")
    func limits() {
        let (viewModel, _) = makeViewModel()
        viewModel.name = String(repeating: "a", count: NotificationLocation.nameLimit)
        #expect(viewModel.canConfirm)
        #expect(!viewModel.isNameTooLong)

        viewModel.name += "a"
        #expect(viewModel.isNameTooLong)
        #expect(!viewModel.canConfirm)

        viewModel.name = "Kafe"
        viewModel.address = String(repeating: "b", count: NotificationLocation.addressLimit + 1)
        #expect(viewModel.isAddressTooLong)
        #expect(!viewModel.canConfirm)
    }
}

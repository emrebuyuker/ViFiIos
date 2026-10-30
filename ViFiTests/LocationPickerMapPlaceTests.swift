import Foundation
import Testing
@testable import ViFi

@MainActor
@Suite("LocationPickerViewModel places on the map")
struct LocationPickerMapPlaceTests {
    private typealias Fixture = LocationPickerFixture

    private func makeViewModel(
        initial: NotificationLocation? = nil,
        searcher: StubPlaceSearcher = StubPlaceSearcher()
    ) -> (LocationPickerViewModel, StubPlaceSearcher) {
        (LocationPickerViewModel(initial: initial, searcher: searcher, debounce: .zero), searcher)
    }

    private func tapPastane(on viewModel: LocationPickerViewModel, name: String = Fixture.pastane.name) {
        let place = Fixture.pastane
        viewModel.selectMapPlace(placeId: place.placeId, name: name, latitude: place.latitude, longitude: place.longitude)
    }

    // MARK: Tapping a place

    @Test("Tapping a place picks it at once: name, coordinate and place id, and the map moves onto it")
    func tapPicksThePlace() async throws {
        let (viewModel, searcher) = makeViewModel()
        searcher.addresses[Fixture.pastane.placeId] = .success(Fixture.pastaneAddress)

        tapPastane(on: viewModel)

        #expect(viewModel.name == "A Pastanesi")
        #expect(viewModel.placeId == "poi-1")
        #expect(viewModel.latitude == Fixture.pastane.latitude)
        #expect(viewModel.longitude == Fixture.pastane.longitude)
        #expect(viewModel.isLoadingAddress)
        #expect(viewModel.canConfirm, "The address is optional: the place can be confirmed before it arrives")
        let request = try #require(viewModel.cameraRequest)
        #expect(request.camera == MapCamera(
            latitude: Fixture.pastane.latitude,
            longitude: Fixture.pastane.longitude,
            zoom: LocationPickerViewModel.placeZoom
        ))

        await viewModel.finishAddressLookup()

        #expect(searcher.addressLookups == ["poi-1"])
        #expect(viewModel.address == Fixture.pastaneAddress)
        #expect(!viewModel.isLoadingAddress)
        #expect(viewModel.location == NotificationLocation(
            latitude: Fixture.pastane.latitude,
            longitude: Fixture.pastane.longitude,
            name: "A Pastanesi",
            address: Fixture.pastaneAddress,
            placeId: "poi-1"
        ))
    }

    @Test("The address arrives after the tap and fills the field then")
    func addressArrivesLater() async {
        let gate = AsyncGate()
        let (viewModel, searcher) = makeViewModel()
        searcher.addressGate = gate
        searcher.addresses[Fixture.pastane.placeId] = .success(Fixture.pastaneAddress)

        tapPastane(on: viewModel)
        await gate.waitForArrival()
        #expect(viewModel.address.isEmpty)
        #expect(viewModel.isLoadingAddress)

        gate.open()
        await viewModel.finishAddressLookup()

        #expect(viewModel.address == Fixture.pastaneAddress)
        #expect(!viewModel.isLoadingAddress)
    }

    @Test("A failed address lookup keeps the place, without an address")
    func addressFailure() async {
        let (viewModel, searcher) = makeViewModel()
        searcher.addresses[Fixture.pastane.placeId] = .failure(PlaceSearchError.unavailable)

        tapPastane(on: viewModel)
        await viewModel.finishAddressLookup()

        #expect(viewModel.name == "A Pastanesi")
        #expect(viewModel.placeId == "poi-1")
        #expect(viewModel.address.isEmpty)
        #expect(!viewModel.isLoadingAddress)
        #expect(viewModel.resolveError == nil, "Nothing to report: the address is optional")
        #expect(viewModel.canConfirm)
    }

    @Test("An address the admin types while the lookup runs is kept")
    func typedAddressWins() async {
        let gate = AsyncGate()
        let (viewModel, searcher) = makeViewModel()
        searcher.addressGate = gate
        searcher.addresses[Fixture.pastane.placeId] = .success(Fixture.pastaneAddress)

        tapPastane(on: viewModel)
        await gate.waitForArrival()
        viewModel.address = "Arka kapı"
        gate.open()
        await viewModel.finishAddressLookup()

        #expect(viewModel.address == "Arka kapı")
        #expect(!viewModel.isLoadingAddress)
    }

    @Test("A newer tap drops the older place's address")
    func newerTapWins() async {
        let gate = AsyncGate()
        let (viewModel, searcher) = makeViewModel()
        searcher.addressGate = gate
        searcher.addresses = ["poi-1": .success(Fixture.pastaneAddress), "poi-2": .success("Ortaköy, Beşiktaş")]

        tapPastane(on: viewModel)
        await gate.waitForArrival()
        viewModel.selectMapPlace(placeId: "poi-2", name: "B Kafe", latitude: 41.05, longitude: 29.02)
        gate.open()
        await viewModel.finishAddressLookup()
        // Let the dropped first lookup finish too; it must not write.
        await Task.yield()

        #expect(viewModel.name == "B Kafe")
        #expect(viewModel.placeId == "poi-2")
        #expect(viewModel.address == "Ortaköy, Beşiktaş")
        #expect(!viewModel.isLoadingAddress)
    }

    @Test("A search result chosen while a tapped place's address loads replaces it entirely")
    func searchAfterTap() async {
        let gate = AsyncGate()
        let (viewModel, searcher) = makeViewModel()
        searcher.addressGate = gate
        searcher.addresses[Fixture.pastane.placeId] = .success(Fixture.pastaneAddress)

        tapPastane(on: viewModel)
        await gate.waitForArrival()
        await viewModel.select(Fixture.suggestion)
        gate.open()
        await Task.yield()

        #expect(viewModel.name == Fixture.kadikoy.name)
        #expect(viewModel.address == Fixture.kadikoy.address)
        #expect(viewModel.placeId == Fixture.kadikoy.placeId)
        #expect(!viewModel.isLoadingAddress)
    }

    @Test("A place tapped while a search result resolves wins over it")
    func tapWhileResolving() async throws {
        let gate = AsyncGate()
        let (viewModel, searcher) = makeViewModel()
        searcher.placeGate = gate

        let selecting = Task { await viewModel.select(Fixture.suggestion) }
        await gate.waitForArrival()
        tapPastane(on: viewModel)
        gate.open()
        await selecting.value

        #expect(viewModel.name == "A Pastanesi")
        #expect(viewModel.placeId == "poi-1")
        #expect(try #require(viewModel.cameraRequest).camera.latitude == Fixture.pastane.latitude)
        #expect(!viewModel.isResolving)
    }

    @Test("Tapping replaces an earlier place's name and address")
    func tapReplacesEarlierPlace() async {
        let (viewModel, _) = makeViewModel()
        await viewModel.select(Fixture.suggestion)

        tapPastane(on: viewModel)
        await viewModel.finishAddressLookup()

        #expect(viewModel.name == "A Pastanesi")
        #expect(viewModel.address.isEmpty, "A place without an address leaves none, not the old place's")
    }

    @Test("Tapping closes the search list and empties the box")
    func tapEndsTheSearch() async {
        let (viewModel, searcher) = makeViewModel()
        searcher.suggestionsResult = .success([Fixture.suggestion])
        viewModel.updateQuery("Kadıköy")
        await viewModel.finishSearch()

        tapPastane(on: viewModel)

        #expect(viewModel.query.isEmpty)
        #expect(viewModel.searchState == .idle)
    }

    @Test("Dragging off a tapped place drops its id but keeps the name and address, as after a search")
    func dragAfterTap() async {
        let (viewModel, searcher) = makeViewModel()
        searcher.addresses[Fixture.pastane.placeId] = .success(Fixture.pastaneAddress)
        tapPastane(on: viewModel)
        await viewModel.finishAddressLookup()

        viewModel.mapDidSettle(latitude: Fixture.pastane.latitude + 0.0000001, longitude: Fixture.pastane.longitude)
        #expect(viewModel.placeId == "poi-1", "The move onto the place ends a hair off; still the place")

        viewModel.mapWillMoveByGesture()
        viewModel.mapDidSettle(latitude: 41.06, longitude: 29.01)
        #expect(viewModel.placeId == nil)
        #expect(viewModel.name == "A Pastanesi")
        #expect(viewModel.address == Fixture.pastaneAddress)
        #expect(viewModel.location?.placeId == nil)
    }

    @Test("A label over two lines becomes one line; a very long one is cut to the limit")
    func labelCleanup() {
        let (viewModel, _) = makeViewModel()

        tapPastane(on: viewModel, name: "  A Pastanesi\nBeşiktaş ")
        #expect(viewModel.name == "A Pastanesi Beşiktaş")

        tapPastane(on: viewModel, name: String(repeating: "a", count: NotificationLocation.nameLimit + 10))
        #expect(viewModel.name.count == NotificationLocation.nameLimit)
    }

    @Test("Zoomed in past street level, tapping keeps the zoom instead of zooming out")
    func tapKeepsCloserZoom() throws {
        let (viewModel, _) = makeViewModel()
        viewModel.mapDidSettle(latitude: 41.04, longitude: 29.0, zoom: 18.5)

        tapPastane(on: viewModel)

        #expect(try #require(viewModel.cameraRequest).camera.zoom == 18.5)
    }

    // MARK: Search area

    @Test("Searches favor what the map shows once it is zoomed in")
    func searchFavorsTheMap() async {
        let (viewModel, searcher) = makeViewModel()
        viewModel.mapDidSettle(latitude: 41.04, longitude: 29.0, zoom: 14, visibleRadius: 3_000)

        viewModel.updateQuery("pastane")
        await viewModel.finishSearch()

        #expect(searcher.areas == [SearchArea(latitude: 41.04, longitude: 29.0, radius: 3_000)])
    }

    @Test("Before the map settles and on a country-wide view, searches favor no area")
    func noAreaWhenZoomedOut() async {
        let (viewModel, searcher) = makeViewModel()
        viewModel.updateQuery("pastane")
        await viewModel.finishSearch()

        viewModel.mapDidSettle(latitude: 41.04, longitude: 29.0, zoom: 14, visibleRadius: 3_000)
        viewModel.mapDidSettle(latitude: 39, longitude: 35, zoom: 5, visibleRadius: SearchArea.maximumRadius * 10)
        viewModel.updateQuery("kafe")
        await viewModel.finishSearch()

        #expect(searcher.areas == [nil, nil])
    }
}

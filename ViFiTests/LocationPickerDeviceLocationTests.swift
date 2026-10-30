import Foundation
import Testing
@testable import ViFi

@MainActor
@Suite("LocationPickerViewModel device location")
struct LocationPickerDeviceLocationTests {
    private typealias Fixture = LocationPickerFixture

    private func makeViewModel(
        initial: NotificationLocation? = nil,
        locator: StubDeviceLocator,
        searcher: StubPlaceSearcher = StubPlaceSearcher()
    ) -> LocationPickerViewModel {
        LocationPickerViewModel(initial: initial, searcher: searcher, locator: locator, debounce: .zero)
    }

    private var hereCamera: MapCamera {
        MapCamera(latitude: Fixture.here.latitude, longitude: Fixture.here.longitude, zoom: LocationPickerViewModel.placeZoom)
    }

    // MARK: Permission and first fix

    @Test("Never asked: asks once, then opens on the first fix at street level")
    func asksThenFocuses() async throws {
        let locator = StubDeviceLocator(authorization: .notDetermined, answer: .authorized)
        let viewModel = makeViewModel(locator: locator)

        await viewModel.locateDevice()

        #expect(locator.requestCount == 1)
        #expect(locator.locateCount == 1)
        #expect(viewModel.locationAuthorization == .authorized)
        #expect(viewModel.showsDeviceLocation)
        #expect(!viewModel.isLocationDenied)
        let request = try #require(viewModel.cameraRequest)
        #expect(request.camera == hereCamera)
        // Only the camera moves: nothing is picked until the map settles and the admin names the place.
        #expect(viewModel.placeId == nil)
        #expect(viewModel.name.isEmpty)
        #expect(viewModel.location == nil)
    }

    @Test("Already allowed: no prompt, straight to the fix")
    func alreadyAllowed() async throws {
        let locator = StubDeviceLocator(authorization: .authorized)
        let viewModel = makeViewModel(locator: locator)

        await viewModel.locateDevice()

        #expect(locator.requestCount == 0)
        #expect(try #require(viewModel.cameraRequest).camera == hereCamera)
    }

    @Test("It runs once per picker, however often the screen appears")
    func runsOnce() async throws {
        let locator = StubDeviceLocator(authorization: .notDetermined)
        let viewModel = makeViewModel(locator: locator)

        await viewModel.locateDevice()
        await viewModel.locateDevice()

        #expect(locator.requestCount == 1)
        #expect(locator.locateCount == 1)
        #expect(try #require(viewModel.cameraRequest).id == 1)
    }

    @Test("An approximate fix (Precise Location off) opens on the district, not a street")
    func approximateFix() async throws {
        let locator = StubDeviceLocator(fix: DeviceCoordinate(latitude: 41.0, longitude: 29.0, accuracy: 3_000))
        let viewModel = makeViewModel(locator: locator)

        await viewModel.locateDevice()

        #expect(try #require(viewModel.cameraRequest).camera.zoom == LocationPickerViewModel.approximateZoom)
    }

    @Test(
        "Refused now or before: no fix is read, the map stays on Turkey, and the picker only notes it",
        arguments: [LocationAuthorization.notDetermined, .denied]
    )
    func refused(startingAs authorization: LocationAuthorization) async {
        let locator = StubDeviceLocator(authorization: authorization, answer: .denied)
        let viewModel = makeViewModel(locator: locator)

        await viewModel.locateDevice()

        #expect(locator.requestCount == (authorization == .notDetermined ? 1 : 0), "A refusal is never asked again")
        #expect(locator.locateCount == 0)
        #expect(viewModel.cameraRequest == nil)
        #expect(viewModel.initialCamera == LocationPickerViewModel.defaultCamera)
        #expect(viewModel.isLocationDenied)
        #expect(!viewModel.showsDeviceLocation)

        // The picker works as before.
        viewModel.mapDidSettle(latitude: 41, longitude: 29)
        viewModel.name = "Kafe"
        #expect(viewModel.canConfirm)
    }

    @Test("No fix (unavailable or cancelled) leaves the map where it is")
    func noFix() async {
        let locator = StubDeviceLocator(fix: nil)
        let viewModel = makeViewModel(locator: locator)

        await viewModel.locateDevice()

        #expect(viewModel.cameraRequest == nil)
        #expect(viewModel.showsDeviceLocation, "The dot still shows once a fix comes in")
    }

    @Test("Without a locator (previews, mock mode) nothing is asked")
    func withoutLocator() async {
        let viewModel = LocationPickerViewModel(searcher: StubPlaceSearcher())

        await viewModel.locateDevice()

        #expect(viewModel.locationAuthorization == nil)
        #expect(!viewModel.showsDeviceLocation)
        #expect(!viewModel.isLocationDenied)
        #expect(viewModel.cameraRequest == nil)
    }

    // MARK: The admin comes first

    @Test("Changing a location keeps the map on it: permission is asked for the dot, but no fix is read")
    func editingKeepsTheLocation() async {
        let initial = NotificationLocation(latitude: 38.5, longitude: 27.1, name: "Kafe", address: nil, placeId: "p1")
        let locator = StubDeviceLocator(authorization: .notDetermined)
        let viewModel = makeViewModel(initial: initial, locator: locator)

        await viewModel.locateDevice()

        #expect(locator.requestCount == 1)
        #expect(locator.locateCount == 0)
        #expect(viewModel.cameraRequest == nil)
        #expect(viewModel.showsDeviceLocation)
        #expect(viewModel.location == initial)
    }

    @Test("A drag before the fix arrives keeps the map where the admin took it")
    func dragBeforeFix() async {
        let gate = AsyncGate()
        let locator = StubDeviceLocator()
        locator.fixGate = gate
        let viewModel = makeViewModel(locator: locator)

        let locating = Task { await viewModel.locateDevice() }
        await gate.waitForArrival()
        viewModel.mapWillMoveByGesture()
        gate.open()
        await locating.value

        #expect(locator.locateCount == 1)
        #expect(viewModel.cameraRequest == nil)
    }

    @Test("A drag while the permission prompt is up means no fix is read at all")
    func dragDuringPrompt() async {
        let gate = AsyncGate()
        let locator = StubDeviceLocator(authorization: .notDetermined)
        locator.promptGate = gate
        let viewModel = makeViewModel(locator: locator)

        let locating = Task { await viewModel.locateDevice() }
        await gate.waitForArrival()
        viewModel.mapWillMoveByGesture()
        gate.open()
        await locating.value

        #expect(locator.locateCount == 0)
        #expect(viewModel.cameraRequest == nil)
        #expect(viewModel.showsDeviceLocation)
    }

    @Test("A search result chosen before the fix arrives wins")
    func searchBeforeFix() async throws {
        let gate = AsyncGate()
        let locator = StubDeviceLocator()
        locator.fixGate = gate
        let viewModel = makeViewModel(locator: locator)

        let locating = Task { await viewModel.locateDevice() }
        await gate.waitForArrival()
        await viewModel.select(Fixture.suggestion)
        gate.open()
        await locating.value

        let request = try #require(viewModel.cameraRequest)
        #expect(request.id == 1)
        #expect(request.camera.latitude == Fixture.kadikoy.latitude)
        #expect(viewModel.placeId == Fixture.kadikoy.placeId)
    }

    @Test("A search result still resolving when the fix arrives wins")
    func searchResolvingAtFix() async throws {
        let gate = AsyncGate()
        let searcher = StubPlaceSearcher()
        searcher.placeGate = gate
        let viewModel = makeViewModel(locator: StubDeviceLocator(), searcher: searcher)

        let selecting = Task { await viewModel.select(Fixture.suggestion) }
        await gate.waitForArrival()
        await viewModel.locateDevice()
        #expect(viewModel.cameraRequest == nil)
        gate.open()
        await selecting.value

        #expect(try #require(viewModel.cameraRequest).camera.latitude == Fixture.kadikoy.latitude)
    }

    @Test("A place tapped on the map before the fix arrives wins")
    func tapBeforeFix() async throws {
        let gate = AsyncGate()
        let locator = StubDeviceLocator()
        locator.fixGate = gate
        let viewModel = makeViewModel(locator: locator)
        let place = Fixture.pastane

        let locating = Task { await viewModel.locateDevice() }
        await gate.waitForArrival()
        viewModel.selectMapPlace(placeId: place.placeId, name: place.name, latitude: place.latitude, longitude: place.longitude)
        gate.open()
        await locating.value

        let request = try #require(viewModel.cameraRequest)
        #expect(request.id == 1)
        #expect(request.camera.latitude == place.latitude)
    }
}

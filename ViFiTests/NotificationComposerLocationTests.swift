import Foundation
import Testing
@testable import ViFi

/// The composer's "Konum" action: choosing a place, and that a location notification is always a campaign.
@MainActor
@Suite("NotificationComposerViewModel location action")
struct NotificationComposerLocationTests {
    private let fixture = NotificationComposerFixture()

    private static let cafe = NotificationLocation(
        latitude: 40.9903,
        longitude: 29.029,
        name: "ViFi Öğrenci Kafesi",
        address: "Caferağa, Kadıköy",
        placeId: "place-1"
    )

    @Test("Choosing Konum without a place blocks sending and says why")
    func needsAPlace() {
        let (viewModel, _) = fixture.readyViewModel()

        viewModel.actionChoice = .location

        #expect(viewModel.issue == .invalidLocation)
        #expect(viewModel.visibleIssue == .invalidLocation)
        #expect(!viewModel.canSend)
        #expect(!viewModel.canSendTest)
        #expect(viewModel.draft.action == nil, "It must not go out as if no action was chosen")
    }

    @Test("A picked place becomes the draft's location action")
    func pickedPlace() {
        let (viewModel, _) = fixture.readyViewModel()
        viewModel.actionChoice = .location

        viewModel.location = Self.cafe

        #expect(viewModel.issue == nil)
        #expect(viewModel.canSend)
        #expect(viewModel.draft.action == .location(Self.cafe))
    }

    @Test("A location notification always goes as a campaign, whatever the kind says")
    func alwaysPromo() {
        let (viewModel, _) = fixture.readyViewModel()
        viewModel.kind = .general
        viewModel.actionChoice = .location
        viewModel.location = Self.cafe

        #expect(viewModel.draft.effectiveKind == .promo)
        #expect(viewModel.draft.payload["kind"] as? String == "promo")
    }

    @Test("The place travels in the payload with its optional parts")
    func payload() throws {
        let (viewModel, _) = fixture.readyViewModel()
        viewModel.actionChoice = .location
        viewModel.location = Self.cafe

        let action = try #require(viewModel.draft.payload["action"] as? [String: Any])
        #expect(action["type"] as? String == "location")
        #expect(action["latitude"] as? Double == 40.9903)
        #expect(action["longitude"] as? Double == 29.029)
        #expect(action["name"] as? String == "ViFi Öğrenci Kafesi")
        #expect(action["address"] as? String == "Caferağa, Kadıköy")
        #expect(action["placeId"] as? String == "place-1")

        viewModel.location = NotificationLocation(latitude: 1, longitude: 2, name: "Nokta", address: nil, placeId: nil)
        let bare = try #require(viewModel.draft.payload["action"] as? [String: Any])
        #expect(bare["address"] == nil)
        #expect(bare["placeId"] == nil)
    }

    @Test("A place the server would refuse blocks sending")
    func invalidPlace() {
        let (viewModel, _) = fixture.readyViewModel()
        viewModel.actionChoice = .location

        viewModel.location = NotificationLocation(latitude: 95, longitude: 0, name: "Kutup", address: nil, placeId: nil)
        #expect(viewModel.issue == .invalidLocation)

        viewModel.location = NotificationLocation(latitude: 1, longitude: 2, name: "  ", address: nil, placeId: nil)
        #expect(viewModel.issue == .invalidLocation)

        viewModel.location = Self.cafe
        #expect(viewModel.issue == nil)
    }

    @Test("The picked place is kept while another action is chosen, but only a chosen Konum sends it")
    func keptButNotSent() {
        let (viewModel, _) = fixture.readyViewModel()
        viewModel.actionChoice = .location
        viewModel.location = Self.cafe

        viewModel.actionChoice = .paywall
        #expect(viewModel.draft.action == .paywall)
        #expect(viewModel.draft.effectiveKind == .general)

        viewModel.actionChoice = .noAction
        #expect(viewModel.draft.action == nil)

        viewModel.actionChoice = .location
        #expect(viewModel.draft.action == .location(Self.cafe), "Coming back finds the place still chosen")
    }

    @Test("Send previews and sends the campaign, then clears the place for the next notification")
    func sendFlow() async throws {
        let (viewModel, service) = fixture.readyViewModel()
        viewModel.kind = .general
        viewModel.actionChoice = .location
        viewModel.location = Self.cafe

        await viewModel.requestSend()

        let request = try #require(service.previewRequests.first)
        #expect(request.kind == .promo, "The reach shown is the campaign audience, who opted in")

        await viewModel.confirmSend()

        let sent = try #require(service.sentDrafts.first)
        #expect(sent.action == .location(Self.cafe))
        #expect(sent.effectiveKind == .promo)
        #expect(viewModel.successMessage != nil)
        #expect(viewModel.location == nil)
        #expect(viewModel.actionChoice == .noAction)
    }

    @Test("A test send carries the place too")
    func testSend() async throws {
        let (viewModel, service) = fixture.readyViewModel()
        viewModel.actionChoice = .location
        viewModel.location = Self.cafe

        await viewModel.sendTest()

        let sent = try #require(service.sentDrafts.first)
        #expect(sent.isTest)
        #expect(sent.action == .location(Self.cafe))
    }
}

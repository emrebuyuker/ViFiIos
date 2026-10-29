import Foundation
import Testing
@testable import ViFi

/// The composer's "Tür" control while the action is Konum: it shows Kampanya and cannot be changed, and the admin's
/// own choice comes back when another action is chosen.
@MainActor
@Suite("NotificationComposerViewModel kind lock")
struct NotificationComposerKindLockTests {
    private let fixture = NotificationComposerFixture()

    private static let cafe = NotificationLocation(
        latitude: 40.9903,
        longitude: 29.029,
        name: "ViFi Öğrenci Kafesi",
        address: "Caferağa, Kadıköy",
        placeId: "place-1"
    )

    @Test("Without a location action the kind is the admin's choice and can be changed")
    func unlockedByDefault() {
        let (viewModel, _) = fixture.readyViewModel()

        #expect(!viewModel.isKindLocked)
        #expect(viewModel.kindSelection == .general)

        viewModel.kindSelection = .promo
        #expect(viewModel.kind == .promo)
        #expect(viewModel.effectiveKind == .promo)

        for choice in [.noAction, .paywall, .addExam, .url, .exam] as [NotificationComposerViewModel.ActionChoice] {
            viewModel.actionChoice = choice
            #expect(!viewModel.isKindLocked, "\(choice) must not lock the kind")
            #expect(viewModel.kindSelection == .promo)
        }
    }

    @Test("Choosing Konum shows Kampanya and locks the control, even before a place is picked")
    func locksOnKonum() {
        let (viewModel, _) = fixture.readyViewModel()
        viewModel.kindSelection = .general

        viewModel.actionChoice = .location

        #expect(viewModel.isKindLocked)
        #expect(viewModel.kindSelection == .promo)
        #expect(viewModel.effectiveKind == .promo)
        #expect(viewModel.draft.kind == .promo, "The draft already says campaign; only the missing place blocks sending")
        #expect(viewModel.draft.effectiveKind == .promo)
    }

    @Test("A change to the locked control is ignored")
    func lockedControlIgnoresChanges() {
        let (viewModel, _) = fixture.readyViewModel()
        viewModel.kindSelection = .general
        viewModel.actionChoice = .location

        viewModel.kindSelection = .general

        #expect(viewModel.kindSelection == .promo)
        #expect(viewModel.kind == .general, "The admin's own choice must be left as it was")
    }

    @Test("Switching away from Konum restores the admin's previous choice")
    func restoresTheChoice() {
        let (viewModel, _) = fixture.readyViewModel()

        viewModel.kindSelection = .general
        viewModel.actionChoice = .location
        viewModel.actionChoice = .paywall
        #expect(!viewModel.isKindLocked)
        #expect(viewModel.kindSelection == .general)
        #expect(viewModel.draft.kind == .general)

        viewModel.kindSelection = .promo
        viewModel.actionChoice = .location
        #expect(viewModel.kindSelection == .promo)
        viewModel.actionChoice = .noAction
        #expect(viewModel.kindSelection == .promo)
    }

    @Test("Going back and forth keeps whatever was chosen last while unlocked")
    func choiceMadeBetweenLocks() {
        let (viewModel, _) = fixture.readyViewModel()
        viewModel.kindSelection = .promo

        viewModel.actionChoice = .location
        viewModel.actionChoice = .url
        viewModel.kindSelection = .general
        viewModel.actionChoice = .location

        #expect(viewModel.kindSelection == .promo)
        viewModel.actionChoice = .addExam
        #expect(viewModel.kindSelection == .general)
    }

    @Test("A location campaign is previewed and sent as a campaign; the kind goes back to Duyuru for the next one")
    func sendsAsCampaignThenResets() async throws {
        let (viewModel, service) = fixture.readyViewModel()
        viewModel.kindSelection = .general
        viewModel.actionChoice = .location
        viewModel.location = Self.cafe

        await viewModel.requestSend()
        #expect(service.previewRequests.first?.kind == .promo)
        await viewModel.confirmSend()

        let sent = try #require(service.sentDrafts.first)
        #expect(sent.kind == .promo)
        #expect(sent.payload["kind"] as? String == "promo")
        #expect(!viewModel.isKindLocked, "The form is reset for the next notification")
        #expect(viewModel.kindSelection == .general)
    }

    @Test("The locked control does not stop the campaign from being a campaign when sent as a test")
    func testSendIsACampaignToo() async throws {
        let (viewModel, service) = fixture.readyViewModel()
        viewModel.actionChoice = .location
        viewModel.location = Self.cafe

        await viewModel.sendTest()

        let sent = try #require(service.sentDrafts.first)
        #expect(sent.isTest)
        #expect(sent.kind == .promo)
    }
}

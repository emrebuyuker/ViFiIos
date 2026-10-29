import Foundation
import Testing
@testable import ViFi

@MainActor
@Suite("NotificationComposerViewModel sending")
struct NotificationComposerSendFlowTests {
    private let fixture = NotificationComposerFixture()
    private var clock: TestClock { fixture.clock }

    // MARK: Send flow

    @Test("Send previews first and sends only after confirmation")
    func previewConfirmSend() async throws {
        let service = StubNotificationAdminService()
        service.previewResult = .success(NotificationPreview(recipients: 12, pushTargets: 15))
        let (viewModel, _) = fixture.readyViewModel(service: service)
        await viewModel.loadFacetsIfNeeded()
        viewModel.kind = .promo
        viewModel.audienceMode = .segment
        viewModel.selectUniversity("sakarya")
        viewModel.gender = .female
        let idBefore = viewModel.draftId

        await viewModel.requestSend()

        let request = try #require(service.previewRequests.first)
        #expect(request.kind == .promo)
        #expect(request.audience == .segment(
            NotificationSegment(universityId: "sakarya", facultyId: nil, departmentId: nil, gender: .female)
        ))
        #expect(viewModel.isConfirming)
        #expect(viewModel.confirmation?.preview == NotificationPreview(recipients: 12, pushTargets: 15))
        #expect(service.sentDrafts.isEmpty, "Nothing goes out before the admin confirms")

        await viewModel.confirmSend()

        let sent = try #require(service.sentDrafts.first)
        #expect(service.sentDrafts.count == 1)
        #expect(sent.id == idBefore)
        #expect(sent.title == "Başlık")
        #expect(sent.kind == .promo)
        #expect(!sent.isTest)
        #expect(viewModel.successMessage != nil)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.confirmation == nil)
        #expect(!viewModel.isWorking)
        // The form is ready for the next notification, under a new id.
        #expect(viewModel.draftId != idBefore)
        #expect(viewModel.title.isEmpty)
        #expect(viewModel.body.isEmpty)
        #expect(viewModel.audienceMode == .everyone)
        #expect(viewModel.universityId == nil)
        #expect(viewModel.kind == .general)
        #expect(viewModel.facets.value == NotificationComposerFixture.facets, "The facets are kept")
    }

    @Test("Declining the confirmation sends nothing and keeps the form")
    func declining() async {
        let (viewModel, service) = fixture.readyViewModel()
        await viewModel.requestSend()
        #expect(viewModel.isConfirming)

        viewModel.cancelConfirmation()
        await viewModel.confirmSend()

        #expect(service.sentDrafts.isEmpty)
        #expect(!viewModel.isConfirming)
        #expect(viewModel.confirmation == nil)
        #expect(viewModel.title == "Başlık")
    }

    @Test("Dismissing the dialog before its action runs still sends what was confirmed")
    func dialogDismissalDoesNotDropTheSend() async {
        let (viewModel, service) = fixture.readyViewModel()
        await viewModel.requestSend()

        // The system clears the presentation flag before it runs the tapped button's action.
        viewModel.isConfirming = false
        await viewModel.confirmSend()

        #expect(service.sentDrafts.count == 1)
    }

    @Test("A send the form cannot validate never reaches the server")
    func invalidSendIsIgnored() async {
        let (viewModel, service) = fixture.makeViewModel()

        await viewModel.requestSend()
        await viewModel.confirmSend()
        await viewModel.sendTest()

        #expect(service.previewRequests.isEmpty)
        #expect(service.sentDrafts.isEmpty)
        #expect(!viewModel.isConfirming)
    }

    @Test("A scheduled send reports when it goes out")
    func scheduledSend() async throws {
        let service = StubNotificationAdminService()
        let when = clock.date.addingTimeInterval(7200)
        service.sendResult = .success(NotificationSendResult(notificationId: "n", status: .scheduled, scheduledAt: when, recipients: 4))
        let (viewModel, _) = fixture.readyViewModel(service: service)
        viewModel.setScheduling(true)

        await viewModel.requestSend()
        await viewModel.confirmSend()

        let draft = try #require(service.sentDrafts.first)
        #expect(draft.scheduledAt == clock.date.addingTimeInterval(3600))
        #expect(viewModel.successMessage?.contains(when.formatted(date: .abbreviated, time: .shortened)) == true)
        #expect(viewModel.scheduledAt == nil, "The form is reset")
    }

    @Test("A failed send keeps the form and the id, so the retry is the same send")
    func retryKeepsId() async throws {
        let service = StubNotificationAdminService()
        service.sendResult = .failure(NotificationAdminError.offline)
        let (viewModel, _) = fixture.readyViewModel(service: service)
        let id = viewModel.draftId

        await viewModel.requestSend()
        await viewModel.confirmSend()

        #expect(viewModel.errorMessage == NotificationAdminError.offline.userMessage)
        #expect(viewModel.successMessage == nil)
        #expect(viewModel.draftId == id)
        #expect(viewModel.title == "Başlık", "The form is kept for the retry")
        #expect(viewModel.confirmation == nil)
        #expect(viewModel.canSend)

        service.sendResult = nil
        await viewModel.requestSend()
        await viewModel.confirmSend()

        #expect(service.sentDrafts.map(\.id) == [id, id])
        #expect(viewModel.successMessage != nil)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.draftId != id, "A completed send moves on to a new id")
    }

    @Test("A server rejection shows the server's message")
    func serverRejection() async {
        let service = StubNotificationAdminService()
        service.sendResult = .failure(NotificationAdminError.invalidDraft(message: "Görsel henüz desteklenmiyor."))
        let (viewModel, _) = fixture.readyViewModel(service: service)

        await viewModel.requestSend()
        await viewModel.confirmSend()

        #expect(viewModel.errorMessage == "Görsel henüz desteklenmiyor.")
    }

    @Test("A failed record is not reused: the next try is a new notification")
    func failedResultRenewsId() async {
        let service = StubNotificationAdminService()
        service.sendResult = .success(NotificationSendResult(notificationId: "n", status: .failed, scheduledAt: nil, recipients: 0))
        let (viewModel, _) = fixture.readyViewModel(service: service)
        let id = viewModel.draftId

        await viewModel.requestSend()
        await viewModel.confirmSend()

        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.successMessage == nil)
        #expect(viewModel.draftId != id)
        #expect(viewModel.title == "Başlık")
    }

    @Test("A failed preview reports the error and confirms nothing")
    func previewFailure() async {
        let service = StubNotificationAdminService()
        service.previewResult = .failure(NotificationAdminError.permissionDenied)
        let (viewModel, _) = fixture.readyViewModel(service: service)

        await viewModel.requestSend()

        #expect(viewModel.errorMessage == NotificationAdminError.permissionDenied.userMessage)
        #expect(!viewModel.isConfirming)
        #expect(viewModel.confirmation == nil)
        #expect(service.sentDrafts.isEmpty)
        #expect(!viewModel.isWorking)
    }

    @Test("A second tap while a request is in flight is ignored")
    func doubleTapProtection() async {
        let gate = AsyncGate()
        let service = StubNotificationAdminService()
        service.gate = gate
        let (viewModel, _) = fixture.readyViewModel(service: service)

        let first = Task { await viewModel.requestSend() }
        await gate.waitForArrival()
        #expect(viewModel.isWorking)
        #expect(!viewModel.canSend)
        #expect(!viewModel.canSendTest)

        await viewModel.requestSend()
        await viewModel.sendTest()
        #expect(service.previewRequests.count == 1)
        #expect(service.sentDrafts.isEmpty)

        gate.open()
        await first.value
        #expect(!viewModel.isWorking)
        #expect(viewModel.isConfirming)
    }

    // MARK: Test send

    @Test("The test goes to the admin only, under its own id, and leaves the form alone")
    func testSend() async throws {
        let (viewModel, service) = fixture.readyViewModel()
        await viewModel.loadFacetsIfNeeded()
        viewModel.audienceMode = .segment
        viewModel.selectUniversity("sakarya")
        viewModel.setScheduling(true)
        viewModel.setExpiry(true)
        let id = viewModel.draftId

        await viewModel.sendTest()
        await viewModel.sendTest()

        #expect(service.previewRequests.isEmpty, "A test needs no confirmation")
        let first = try #require(service.sentDrafts.first)
        let second = try #require(service.sentDrafts.last)
        #expect(service.sentDrafts.count == 2)
        #expect(first.isTest)
        #expect(first.id != id, "The real draft's id is not used up")
        #expect(first.id != second.id)
        #expect(first.scheduledAt == nil)
        #expect(first.expiresAt == nil)
        #expect(viewModel.draftId == id)
        #expect(viewModel.successMessage != nil)
        #expect(viewModel.title == "Başlık", "The form is kept")
        #expect(viewModel.audienceMode == .segment)
        #expect(viewModel.scheduledAt != nil)
    }

    @Test("A test does not need a finished audience")
    func testSendWithUnfinishedSegment() async throws {
        let (viewModel, service) = fixture.readyViewModel()
        viewModel.audienceMode = .segment
        #expect(viewModel.issue == .invalidAudience)
        #expect(!viewModel.canSend)
        #expect(viewModel.canSendTest)

        await viewModel.sendTest()

        let draft = try #require(service.sentDrafts.first)
        #expect(draft.audience == .all)
        #expect(draft.isTest)
    }

    @Test("A test still needs its content")
    func testSendNeedsContent() async {
        let (viewModel, service) = fixture.makeViewModel()
        viewModel.title = "Başlık"

        await viewModel.sendTest()

        #expect(service.sentDrafts.isEmpty)
    }

    @Test("A failed test reports the error")
    func testSendFailure() async {
        let service = StubNotificationAdminService()
        service.sendResult = .failure(NotificationAdminError.offline)
        let (viewModel, _) = fixture.readyViewModel(service: service)

        await viewModel.sendTest()

        #expect(viewModel.errorMessage == NotificationAdminError.offline.userMessage)
        #expect(viewModel.successMessage == nil)
    }

    @Test("A campaign is previewed and sent as a campaign")
    func kindIsSent() async throws {
        let (viewModel, service) = fixture.readyViewModel()
        viewModel.kind = .promo

        await viewModel.requestSend()
        await viewModel.confirmSend()

        let draft = try #require(service.sentDrafts.first)
        #expect(service.previewRequests.first?.kind == .promo)
        #expect(draft.payload["kind"] as? String == "promo")
    }
}

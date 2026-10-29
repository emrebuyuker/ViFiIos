import Foundation
import Testing
@testable import ViFi

@MainActor
@Suite("NotificationComposerViewModel")
struct NotificationComposerViewModelTests {
    private let fixture = NotificationComposerFixture()
    private var clock: TestClock { fixture.clock }

    // MARK: Validation

    @Test("An untouched form is blocked but does not scold")
    func untouchedForm() {
        let (viewModel, _) = fixture.makeViewModel()

        #expect(viewModel.issue == .emptyTitle)
        #expect(viewModel.visibleIssue == nil)
        #expect(!viewModel.canSend)
        #expect(!viewModel.canSendTest)
    }

    @Test("Title and message are required, limited and counted")
    func textRules() {
        let (viewModel, _) = fixture.makeViewModel()

        viewModel.title = "   "
        #expect(viewModel.visibleIssue == .emptyTitle, "A blank title the admin typed is flagged")

        viewModel.title = String(repeating: "a", count: NotificationDraft.titleLimit + 1)
        #expect(viewModel.issue == .titleTooLong)
        #expect(viewModel.titleLength == NotificationDraft.titleLimit + 1)

        viewModel.title = "Başlık"
        #expect(viewModel.issue == .emptyBody)

        viewModel.body = String(repeating: "a", count: NotificationDraft.bodyLimit + 1)
        #expect(viewModel.issue == .bodyTooLong)

        viewModel.body = "Mesaj"
        #expect(viewModel.issue == nil)
        #expect(viewModel.canSend)
    }

    @Test("A segment needs a university")
    func segmentNeedsUniversity() async {
        let (viewModel, _) = fixture.readyViewModel()
        await viewModel.loadFacetsIfNeeded()

        viewModel.audienceMode = .segment
        #expect(viewModel.issue == .invalidAudience)

        viewModel.selectUniversity("sakarya")
        #expect(viewModel.issue == nil)
        #expect(viewModel.draft.audience == .segment(
            NotificationSegment(universityId: "sakarya", facultyId: nil, departmentId: nil, gender: nil)
        ))
    }

    @Test("A link must parse and be https; the other actions need nothing")
    func actionValidation() throws {
        let (viewModel, _) = fixture.readyViewModel()

        viewModel.actionChoice = .url
        #expect(viewModel.issue == .invalidURL, "An empty link is not 'no action'")

        viewModel.urlText = "http://example.com"
        #expect(viewModel.issue == .invalidURL)

        viewModel.urlText = "  https://example.com/kampanya  "
        #expect(viewModel.issue == nil)
        #expect(viewModel.draft.action == .url(try #require(URL(string: "https://example.com/kampanya"))))

        viewModel.actionChoice = .paywall
        #expect(viewModel.draft.action == .paywall)
        viewModel.actionChoice = .addExam
        #expect(viewModel.draft.action == .addExam)
        viewModel.actionChoice = .noAction
        #expect(viewModel.draft.action == nil)
    }

    @Test("Scheduling defaults to an hour ahead and the validity follows the delivery")
    func timing() {
        let (viewModel, _) = fixture.readyViewModel()

        viewModel.setScheduling(true)
        #expect(viewModel.scheduledAt == clock.date.addingTimeInterval(3600))
        #expect(viewModel.issue == nil)

        viewModel.setExpiry(true)
        #expect(viewModel.expiresAt == clock.date.addingTimeInterval(3600 + 7 * 24 * 3600))
        #expect(viewModel.issue == nil)

        viewModel.expiresAt = clock.date.addingTimeInterval(1800)
        #expect(viewModel.issue == .expiryBeforeDelivery)

        viewModel.scheduledAt = clock.date.addingTimeInterval(-3 * 3600)
        #expect(viewModel.issue == .scheduleInPast)

        viewModel.setScheduling(false)
        viewModel.setExpiry(false)
        #expect(viewModel.scheduledAt == nil)
        #expect(viewModel.expiresAt == nil)
    }

    // MARK: Facets and the cascade

    @Test("Facets load once, and a failure can be retried")
    func facetsLoading() async {
        let service = StubNotificationAdminService()
        service.facetsResult = .failure(NotificationAdminError.offline)
        let viewModel = NotificationComposerViewModel(service: service, now: clock.now)

        await viewModel.loadFacetsIfNeeded()
        if case .failed = viewModel.facets {} else {
            Issue.record("Expected the failed state")
        }
        #expect(viewModel.estimatedRecipients == nil)

        service.facetsResult = .success(NotificationComposerFixture.facets)
        await viewModel.loadFacetsIfNeeded()
        if case .failed = viewModel.facets {} else {
            Issue.record("loadFacetsIfNeeded should not reload by itself")
        }

        await viewModel.reloadFacets()
        #expect(viewModel.facets.value == NotificationComposerFixture.facets)
    }

    @Test("Each picker lists only what the facets hold, sorted for a Turkish reader")
    func pickerOptions() async {
        let (viewModel, _) = fixture.makeViewModel()
        await viewModel.loadFacetsIfNeeded()

        #expect(viewModel.universities.map(\.id) == ["ankara", "sakarya", "zonguldak"])
        #expect(viewModel.faculties.isEmpty, "No university chosen yet")

        viewModel.selectUniversity("sakarya")
        #expect(viewModel.faculties.map(\.id) == ["iibf", "muhendislik"])
        #expect(viewModel.departments.isEmpty, "No faculty chosen yet")

        viewModel.selectFaculty("muhendislik")
        #expect(viewModel.departments.map(\.id) == ["bilgisayar", "makine"])
    }

    @Test("Changing a level resets the levels below it")
    func cascadingReset() async {
        let (viewModel, _) = fixture.makeViewModel()
        await viewModel.loadFacetsIfNeeded()
        viewModel.selectUniversity("sakarya")
        viewModel.selectFaculty("muhendislik")
        viewModel.selectDepartment("makine")

        viewModel.selectFaculty("iibf")
        #expect(viewModel.universityId == "sakarya")
        #expect(viewModel.facultyId == "iibf")
        #expect(viewModel.departmentId == nil, "A new faculty clears the department")

        viewModel.selectFaculty("muhendislik")
        viewModel.selectDepartment("makine")
        viewModel.selectUniversity("ankara")
        #expect(viewModel.facultyId == nil)
        #expect(viewModel.departmentId == nil, "A new university clears both levels below")

        viewModel.selectUniversity("sakarya")
        viewModel.selectFaculty("muhendislik")
        viewModel.selectDepartment("makine")
        viewModel.selectUniversity("sakarya")
        #expect(viewModel.departmentId == "makine", "Picking the same university again keeps the levels below")
    }

    @Test("A department cannot be chosen without a faculty")
    func departmentNeedsFaculty() async {
        let (viewModel, _) = fixture.makeViewModel()
        await viewModel.loadFacetsIfNeeded()
        viewModel.selectUniversity("sakarya")

        viewModel.selectDepartment("makine")

        #expect(viewModel.departmentId == nil)
    }

    @Test("The estimate follows the audience, level and gender")
    func estimate() async {
        let (viewModel, _) = fixture.makeViewModel()
        #expect(viewModel.estimatedRecipients == nil, "Unknown until the facets arrive")
        await viewModel.loadFacetsIfNeeded()

        #expect(viewModel.estimatedRecipients == 20, "Everyone = all registered profiles")

        viewModel.audienceMode = .segment
        #expect(viewModel.estimatedRecipients == nil, "No university yet")

        viewModel.selectUniversity("sakarya")
        #expect(viewModel.estimatedRecipients == 12)

        viewModel.gender = .female
        #expect(viewModel.estimatedRecipients == 7)

        viewModel.selectFaculty("muhendislik")
        #expect(viewModel.estimatedRecipients == 5)

        viewModel.gender = .male
        viewModel.selectDepartment("makine")
        #expect(viewModel.estimatedRecipients == 2)

        viewModel.gender = nil
        #expect(viewModel.estimatedRecipients == 6)
    }
}

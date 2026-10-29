import Foundation
import ImageIO
import Testing
import UIKit
@testable import ViFi

/// The composer's attachments: the campaign image (downsampled, uploaded under the notification's own id right
/// before it is sent, never replaced) and the exam action (picked from the archive).
@MainActor
@Suite("NotificationComposerViewModel attachments")
struct NotificationComposerAttachmentTests {
    private let fixture = NotificationComposerFixture()

    private static func pngData(width: Int, height: Int, color: UIColor = .systemOrange) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.pngData() ?? Data()
    }

    private static let exam = ArchiveItem(
        path: ArchivePath(
            components: ["uni", "uni__fac", "uni__fac__dep", "uni__fac__dep__course", "exam-42"],
            displayNames: ["Üniversite", "Fakülte", "Bölüm", "Ders", "2024 VİZE"]
        ),
        level: .exam,
        childCount: nil,
        exam: ExamSummary(kind: .pdf, fileCount: 1)
    )

    /// A ready form with an image picked.
    private func readyWithImage(
        service: StubNotificationAdminService = StubNotificationAdminService()
    ) async -> (NotificationComposerViewModel, StubNotificationAdminService) {
        let (viewModel, service) = fixture.readyViewModel(service: service)
        await viewModel.setImage(from: Self.pngData(width: 400, height: 300))
        return (viewModel, service)
    }

    private func send(_ viewModel: NotificationComposerViewModel) async {
        await viewModel.requestSend()
        await viewModel.confirmSend()
    }

    // MARK: Exam action

    @Test("The exam action needs a picked exam, then sends that exam's id")
    func examAction() {
        let (viewModel, _) = fixture.readyViewModel()
        viewModel.actionChoice = .exam

        #expect(viewModel.issue == .emptyExam)
        #expect(!viewModel.canSend)
        #expect(!viewModel.canSendTest)

        viewModel.selectedExam = Self.exam

        #expect(viewModel.issue == nil)
        #expect(viewModel.draft.action == .exam(examId: "exam-42"))
        #expect(viewModel.draft.payload["action"] as? [String: String] == ["type": "exam", "examId": "exam-42"])
        // Not a campaign by itself.
        #expect(viewModel.draft.effectiveKind == .general)
    }

    @Test("Another action drops the picked exam from the draft")
    func otherActionIgnoresExam() {
        let (viewModel, _) = fixture.readyViewModel()
        viewModel.actionChoice = .exam
        viewModel.selectedExam = Self.exam
        viewModel.actionChoice = .paywall
        #expect(viewModel.draft.action == .paywall)
    }

    @Test("A sent exam notification resets the picked exam")
    func resetAfterSend() async throws {
        let (viewModel, service) = fixture.readyViewModel()
        viewModel.actionChoice = .exam
        viewModel.selectedExam = Self.exam

        await send(viewModel)

        #expect(try #require(service.sentDrafts.first).action == .exam(examId: "exam-42"))
        #expect(viewModel.selectedExam == nil)
        #expect(viewModel.actionChoice == .noAction)
    }

    // MARK: Image preparation

    @Test("A picked image is downsampled to 1600 px and encoded as a JPEG within 1 MiB")
    func downsamples() async throws {
        let (viewModel, _) = fixture.readyViewModel()

        await viewModel.setImage(from: Self.pngData(width: 2400, height: 1200))

        let jpeg = try #require(viewModel.image.jpeg)
        #expect(jpeg.starts(with: [0xFF, 0xD8]))
        #expect(jpeg.count <= NotificationImage.maxBytes)
        let source = try #require(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1600)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 800)
        #expect(viewModel.image.preview != nil)
        #expect(!viewModel.image.isPreparing)
    }

    @Test("Data that is not an image is reported and the previous image stays")
    func unusableImage() async {
        let (viewModel, _) = await readyWithImage()
        let previous = viewModel.image.jpeg

        await viewModel.setImage(from: Data([0, 1, 2, 3]))

        #expect(viewModel.image.jpeg == previous)
        #expect(viewModel.image.errorMessage != nil)
    }

    @Test("Removing the image sends the notification without one")
    func removed() async throws {
        let (viewModel, service) = await readyWithImage()
        viewModel.removeImage()

        await send(viewModel)

        #expect(service.uploadRequests.isEmpty)
        #expect(try #require(service.sentDrafts.first).imagePath == nil)
    }

    // MARK: Upload on send

    @Test("The image is uploaded under the notification's id only after the admin confirms")
    func uploadsOnConfirm() async throws {
        let (viewModel, service) = await readyWithImage()
        let id = viewModel.draftId

        await viewModel.requestSend()
        #expect(service.uploadRequests.isEmpty, "Nothing is uploaded before the admin confirms")
        await viewModel.confirmSend()

        #expect(service.uploadRequests.map(\.notificationId) == [id])
        let sent = try #require(service.sentDrafts.first)
        #expect(sent.id == id)
        #expect(sent.imagePath == "notificationImages/\(id).jpg")
        #expect(sent.payload["imagePath"] as? String == "notificationImages/\(id).jpg")
        // The next notification starts without the image.
        #expect(!viewModel.image.hasImage)
    }

    @Test("Declining the confirmation uploads nothing")
    func decliningUploadsNothing() async {
        let (viewModel, service) = await readyWithImage()
        await viewModel.requestSend()
        viewModel.cancelConfirmation()
        #expect(service.uploadRequests.isEmpty)
        #expect(viewModel.image.hasImage)
    }

    @Test("A failed upload sends nothing; the retry uploads under the same id and sends")
    func failedUpload() async throws {
        let service = StubNotificationAdminService()
        service.uploadError = NotificationAdminError.imageUploadFailed
        let (viewModel, _) = await readyWithImage(service: service)
        let id = viewModel.draftId

        await send(viewModel)

        #expect(service.sentDrafts.isEmpty)
        #expect(viewModel.errorMessage == NotificationAdminError.imageUploadFailed.errorDescription)
        #expect(viewModel.draftId == id)
        #expect(viewModel.image.hasImage)

        service.uploadError = nil
        await send(viewModel)

        #expect(service.uploadRequests.map(\.notificationId) == [id, id])
        #expect(try #require(service.sentDrafts.first).imagePath == "notificationImages/\(id).jpg")
    }

    @Test("A send that fails after the upload is retried under the same id, reusing the uploaded image")
    func retryReusesUpload() async throws {
        let service = StubNotificationAdminService()
        service.sendResult = .failure(NotificationAdminError.offline)
        let (viewModel, _) = await readyWithImage(service: service)
        let id = viewModel.draftId

        await send(viewModel)
        #expect(viewModel.errorMessage != nil)

        service.sendResult = nil
        await send(viewModel)

        #expect(service.sentDrafts.map(\.id) == [id, id])
        #expect(service.storedImages.count == 1, "The image is stored once; the retry does not replace it")
        #expect(viewModel.successMessage != nil)
    }

    @Test("A different image after an upload starts a new id; before any upload the id stays")
    func changingTheImage() async {
        let service = StubNotificationAdminService()
        let (viewModel, _) = await readyWithImage(service: service)
        let firstId = viewModel.draftId

        await viewModel.setImage(from: Self.pngData(width: 200, height: 200, color: .systemTeal))
        #expect(viewModel.draftId == firstId, "Nothing was uploaded under it yet")

        service.sendResult = .failure(NotificationAdminError.offline)
        await send(viewModel)
        #expect(service.uploadRequests.map(\.notificationId) == [firstId])

        await viewModel.setImage(from: Self.pngData(width: 300, height: 200, color: .systemPink))
        let secondId = viewModel.draftId
        #expect(secondId != firstId, "The uploaded image of the first id can never be replaced")

        await send(viewModel)
        viewModel.removeImage()
        #expect(viewModel.draftId != secondId)
    }

    @Test("A test send uploads the image under its own fresh id")
    func testSend() async throws {
        let (viewModel, service) = await readyWithImage()
        let draftId = viewModel.draftId

        await viewModel.sendTest()

        let sent = try #require(service.sentDrafts.first)
        #expect(sent.isTest)
        #expect(sent.id != draftId)
        #expect(service.uploadRequests.map(\.notificationId) == [sent.id])
        #expect(sent.imagePath == "notificationImages/\(sent.id).jpg")
        // The real notification keeps its id and image.
        #expect(viewModel.draftId == draftId)
        #expect(viewModel.image.hasImage)
    }

    // MARK: Draft

    @Test("A draft's image must be its own upload")
    func draftImagePath() {
        var draft = NotificationDraft()
        draft.id = "n-1"
        draft.title = "Başlık"
        draft.body = "Mesaj"
        draft.imagePath = "notificationImages/n-1.jpg"
        #expect(draft.validationIssue() == nil)
        draft.imagePath = "notificationImages/other.jpg"
        #expect(draft.validationIssue() == .invalidImage)
    }
}

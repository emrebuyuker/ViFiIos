import Foundation
import Testing
@testable import ViFi

@Suite("ExamSubmissionPayload")
struct ExamSubmissionPayloadTests {
    private static let ownerId = "uid-123"
    private static let submissionId = "sub-456"

    private static func makeSubmission(kind: ExamKind, files: [SubmissionFile]) -> ExamSubmission {
        ExamSubmission(
            university: "Boğaziçi Üniversitesi",
            faculty: "Mühendislik Fakültesi",
            department: "Bilgisayar Mühendisliği",
            lesson: "Ayrık Matematik",
            examName: "Vize",
            year: 2023,
            kind: kind,
            files: files
        )
    }

    private static func make(kind: ExamKind, files: [SubmissionFile]) -> ExamSubmissionPayload {
        ExamSubmissionPayload.make(
            from: makeSubmission(kind: kind, files: files),
            ownerId: ownerId,
            submissionId: submissionId
        )
    }

    @Test("The scalar fields carry the display names, the folded exam text, the kind and the pending status")
    func scalarFields() {
        let payload = Self.make(kind: .images, files: [SubmissionFile(data: Data([1]), order: 1)])

        #expect(payload.ownerId == Self.ownerId)
        #expect(payload.university == "Boğaziçi Üniversitesi")
        #expect(payload.faculty == "Mühendislik Fakültesi")
        #expect(payload.department == "Bilgisayar Mühendisliği")
        #expect(payload.lesson == "Ayrık Matematik")
        #expect(payload.exam == "2023 Vize")
        #expect(payload.kind == "JPG")
        #expect(payload.status == "pending")
    }

    @Test("Image files are named <order>.jpg under pending/<uid>/<submissionId>/ with the JPEG content type")
    func imageUploads() {
        let payload = Self.make(kind: .images, files: [
            SubmissionFile(data: Data([1]), order: 1),
            SubmissionFile(data: Data([2, 2]), order: 2),
        ])

        #expect(payload.files.count == 2)
        let first = payload.files[0]
        #expect(first.fileName == "1.jpg")
        #expect(first.storagePath == "pending/uid-123/sub-456/1.jpg")
        #expect(first.contentType == "image/jpeg")
        #expect(first.order == 1)
        #expect(first.data == Data([1]))
        #expect(payload.files[1].storagePath == "pending/uid-123/sub-456/2.jpg")
    }

    @Test("A PDF file is named 1.pdf with the PDF content type")
    func pdfUpload() throws {
        let payload = Self.make(kind: .pdf, files: [SubmissionFile(data: Data([9]), order: 1)])

        let file = try #require(payload.files.first)
        #expect(file.fileName == "1.pdf")
        #expect(file.storagePath == "pending/uid-123/sub-456/1.pdf")
        #expect(file.contentType == "application/pdf")
    }

    @Test("Files are emitted in ascending order regardless of input order")
    func filesAreSorted() {
        let payload = Self.make(kind: .images, files: [
            SubmissionFile(data: Data([3]), order: 3),
            SubmissionFile(data: Data([1]), order: 1),
            SubmissionFile(data: Data([2]), order: 2),
        ])

        #expect(payload.files.map(\.order) == [1, 2, 3])
        #expect(payload.files.map(\.storagePath) == [
            "pending/uid-123/sub-456/1.jpg",
            "pending/uid-123/sub-456/2.jpg",
            "pending/uid-123/sub-456/3.jpg",
        ])
    }

    @Test("The Firestore files array is [{storagePath, order}], ordered")
    func fileDocuments() {
        let payload = Self.make(kind: .images, files: [
            SubmissionFile(data: Data([2]), order: 2),
            SubmissionFile(data: Data([1]), order: 1),
        ])

        let documents = payload.fileDocuments
        #expect(documents.count == 2)
        #expect(documents[0]["storagePath"] as? String == "pending/uid-123/sub-456/1.jpg")
        #expect(documents[0]["order"] as? Int == 1)
        #expect(documents[1]["storagePath"] as? String == "pending/uid-123/sub-456/2.jpg")
        #expect(documents[1]["order"] as? Int == 2)
    }

    @Test("The Firestore fields are the nine non-timestamp keys of the submissions schema")
    func firestoreFields() {
        let payload = Self.make(kind: .images, files: [SubmissionFile(data: Data([1]), order: 1)])
        let fields = payload.firestoreFields

        #expect(Set(fields.keys) == [
            "ownerId", "university", "faculty", "department", "lesson", "exam", "kind", "status", "files",
        ])
        #expect(fields["createdAt"] == nil) // the server timestamp is added by the live service, not here
        #expect(fields["ownerId"] as? String == "uid-123")
        #expect(fields["exam"] as? String == "2023 Vize")
        #expect(fields["kind"] as? String == "JPG")
        #expect(fields["status"] as? String == "pending")
        #expect((fields["files"] as? [[String: Any]])?.count == 1)
    }
}

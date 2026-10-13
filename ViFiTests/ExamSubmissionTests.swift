import Foundation
import Testing
@testable import ViFi

@Suite("ExamSubmission")
struct ExamSubmissionTests {
    private static func makeFile(order: Int, bytes: Int = 8) -> SubmissionFile {
        SubmissionFile(data: Data(count: bytes), order: order)
    }

    private static func makeSubmission(
        examName: String = "Vize",
        year: Int = 2023,
        kind: ExamKind = .images,
        files: [SubmissionFile]? = nil
    ) -> ExamSubmission {
        ExamSubmission(
            university: "Boğaziçi Üniversitesi",
            faculty: "Mühendislik Fakültesi",
            department: "Bilgisayar Mühendisliği",
            lesson: "Ayrık Matematik",
            examName: examName,
            year: year,
            kind: kind,
            files: files ?? [makeFile(order: 1)]
        )
    }

    // MARK: - examText

    @Test("The stored exam text folds the year in, year first")
    func examTextFoldsYear() {
        #expect(ExamSubmission.examText(name: "Final", year: 2024) == "2024 Final")
    }

    // MARK: - isValidText

    @Test("Text is valid when non-empty and within the length cap", arguments: [
        ("A", true),
        ("", false),
        (String(repeating: "x", count: ExamSubmission.maxTextLength), true),
        (String(repeating: "x", count: ExamSubmission.maxTextLength + 1), false),
    ])
    func isValidText(value: String, expected: Bool) {
        #expect(ExamSubmission.isValidText(value) == expected)
    }

    // MARK: - validationError

    @Test("A well-formed submission has no validation error")
    func validSubmission() {
        #expect(Self.makeSubmission().validationError == nil)
        #expect(Self.makeSubmission().isValid)
    }

    @Test("An empty exam name is invalid text")
    func emptyExamNameInvalid() {
        #expect(Self.makeSubmission(examName: "").validationError == .invalidText)
    }

    @Test("An exam name that overflows once the year is folded in is invalid text")
    func foldedExamTooLong() {
        // name length + " 2023" (5 chars) must stay within maxTextLength.
        let name = String(repeating: "a", count: ExamSubmission.maxTextLength)
        #expect(Self.makeSubmission(examName: name).validationError == .invalidText)
    }

    @Test("A year outside the accepted range is invalid", arguments: [1979, 2101])
    func yearOutOfRange(year: Int) {
        #expect(Self.makeSubmission(year: year).validationError == .invalidYear)
    }

    @Test("A submission with no files is rejected")
    func noFiles() {
        #expect(Self.makeSubmission(files: []).validationError == .noFiles)
    }

    @Test("More than the maximum number of files is rejected")
    func tooManyFiles() {
        let files = (1...(ExamSubmission.maxFileCount + 1)).map { Self.makeFile(order: $0) }
        #expect(Self.makeSubmission(kind: .images, files: files).validationError == .tooManyFiles)
    }

    @Test("A PDF submission must carry exactly one file")
    func pdfMustBeSingleFile() {
        let two = [Self.makeFile(order: 1), Self.makeFile(order: 2)]
        #expect(Self.makeSubmission(kind: .pdf, files: two).validationError == .pdfMustBeSingleFile)
        #expect(Self.makeSubmission(kind: .pdf, files: [Self.makeFile(order: 1)]).validationError == nil)
    }

    @Test("An empty file is rejected and names the offending order")
    func emptyFile() {
        let files = [Self.makeFile(order: 1), SubmissionFile(data: Data(), order: 2)]
        #expect(Self.makeSubmission(kind: .images, files: files).validationError == .emptyFile(order: 2))
    }

    @Test("A file over the size cap is rejected and names the offending order")
    func fileTooLarge() {
        let big = SubmissionFile(data: Data(count: ExamSubmission.maxFileBytes + 1), order: 1)
        #expect(Self.makeSubmission(kind: .pdf, files: [big]).validationError == .fileTooLarge(order: 1))
    }

    // MARK: - ExamKind

    @Test("Exam kind raw values are stable (they are stored in the database)")
    func kindRawValues() {
        #expect(ExamKind.images.rawValue == "JPG")
        #expect(ExamKind.pdf.rawValue == "PDF")
        #expect(ExamKind.images.id == "JPG")
    }

    @Test("Each kind maps to the content type and extension the Storage rules require")
    func kindUploadMetadata() {
        #expect(ExamKind.images.uploadContentType == "image/jpeg")
        #expect(ExamKind.images.fileExtension == "jpg")
        #expect(ExamKind.pdf.uploadContentType == "application/pdf")
        #expect(ExamKind.pdf.fileExtension == "pdf")
    }
}

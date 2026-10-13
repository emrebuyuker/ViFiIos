import Foundation

/// A user-contributed exam awaiting moderation, collected by the "Sınav Ekle" flow before it is written to
/// Cloud Firestore `submissions/<id>` and uploaded to Cloud Storage `pending/<uid>/<submissionId>/…`.
///
/// Pure value type, independent of Firebase, so the form, its validation and the server payload are all
/// unit-testable. The archive path (university → faculty → department → course) is captured as the
/// human-readable display names the server schema stores — the live `submissions` schema is flat denormalized
/// text, with no canonical ids. The free-typed exam name and the year are kept apart here and folded into the
/// single `exam` text field at encode time (see `ExamSubmissionPayload`). The owner's uid is not part of the
/// model; the service takes it from the verified session.
nonisolated struct ExamSubmission: Equatable, Sendable {
    /// Longest accepted value of any single taxonomy/exam text field (matches the Firestore rule's 120-char cap).
    static let maxTextLength = 120
    /// Most files a single submission may carry (matches the Firestore rule `files.size() <= 50`).
    static let maxFileCount = 50
    /// Largest accepted size of one uploaded file, in bytes (matches the Storage rule's 15 MiB cap).
    static let maxFileBytes = 15 * 1024 * 1024
    /// Range of accepted exam years.
    static let yearRange = 1980...2100

    /// University display name, taken from the archive catalog; 1…`maxTextLength` characters.
    let university: String
    let faculty: String
    let department: String
    /// Course (`ders`) display name — the archive's `lesson` level.
    let lesson: String
    /// The free-typed exam name, e.g. "Vize", "Final 1".
    let examName: String
    /// The exam year, chosen from a four-digit picker; folded into the stored `exam` text.
    let year: Int
    let kind: ExamKind
    /// The files to upload, in reading order.
    let files: [SubmissionFile]

    /// The single `exam` text the server stores: the free-typed name with the year folded in (the schema has
    /// no separate year field). Year-prefixed so an admin list sorts chronologically, e.g. "2023 Vize".
    static func examText(name: String, year: Int) -> String {
        "\(year) \(name)"
    }

    /// Whether `value` is an acceptable taxonomy/exam text field: non-empty and within the length cap. The
    /// Firestore rule independently asserts 1…120 characters.
    static func isValidText(_ value: String) -> Bool {
        !value.isEmpty && value.count <= maxTextLength
    }

    /// The first invariant this submission violates, or `nil` when it is ready to send. Mirrors the server
    /// contract (five non-empty text fields ≤120 chars, 1…50 files, a single PDF or many images, each file
    /// 1…15 MiB), so the service can refuse an inconsistent submission before touching the network.
    var validationError: ExamSubmissionValidationError? {
        let fields = [university, faculty, department, lesson, Self.examText(name: examName, year: year)]
        guard !examName.isEmpty, fields.allSatisfy(Self.isValidText) else { return .invalidText }
        guard Self.yearRange.contains(year) else { return .invalidYear }
        guard !files.isEmpty else { return .noFiles }
        guard files.count <= Self.maxFileCount else { return .tooManyFiles }
        if kind == .pdf, files.count != 1 { return .pdfMustBeSingleFile }
        for file in files {
            guard !file.data.isEmpty else { return .emptyFile(order: file.order) }
            guard file.data.count <= Self.maxFileBytes else { return .fileTooLarge(order: file.order) }
        }
        return nil
    }

    /// Whether every server invariant is satisfied.
    var isValid: Bool { validationError == nil }
}

/// One file of a submission: its raw bytes and its position in the exam.
nonisolated struct SubmissionFile: Equatable, Sendable {
    let data: Data
    /// 1-based position in reading order.
    let order: Int
}

/// Why a submission is not ready to send. The server contract is mirrored client-side so an inconsistent
/// submission is refused before any upload.
nonisolated enum ExamSubmissionValidationError: Error, Equatable {
    /// A required text field is empty or longer than `maxTextLength`.
    case invalidText
    case invalidYear
    case noFiles
    case tooManyFiles
    /// A PDF submission must carry exactly one file.
    case pdfMustBeSingleFile
    case emptyFile(order: Int)
    case fileTooLarge(order: Int)
}

extension ExamKind: Identifiable {
    nonisolated var id: String { rawValue }
}

extension ExamKind {
    /// Turkish label shown in the picker.
    nonisolated var label: String {
        switch self {
        case .images: String(localized: "Görsel")
        case .pdf: String(localized: "PDF")
        }
    }

    /// The HTTP content type the Storage rules require for an upload of this kind.
    nonisolated var uploadContentType: String {
        switch self {
        case .images: "image/jpeg"
        case .pdf: "application/pdf"
        }
    }

    /// The file-name extension used when naming an uploaded file.
    nonisolated var fileExtension: String {
        switch self {
        case .images: "jpg"
        case .pdf: "pdf"
        }
    }
}

import Foundation

/// File format of an exam, keyed exactly as stored in the database.
nonisolated enum ExamKind: String, Codable, Sendable, CaseIterable {
    case images = "JPG"
    case pdf = "PDF"
}

/// What an exam contains, known while listing a lesson's exams.
nonisolated struct ExamSummary: Hashable, Codable, Sendable {
    let kind: ExamKind
    /// Number of image pages, or PDF files.
    let fileCount: Int
}

/// One entry of an archive list: a university, faculty, department, lesson or exam.
nonisolated struct ArchiveItem: Identifiable, Hashable, Sendable {
    let path: ArchivePath
    let level: ArchiveLevel
    /// Number of child entries (faculties of a university, …); `nil` for exams.
    let childCount: Int?
    /// Exams only. `nil` when the exam node has no files.
    let exam: ExamSummary?

    var id: ArchivePath { path }
    var name: String { path.name ?? "" }
}

/// The files of a single exam, ready to be displayed.
nonisolated struct ExamDocument: Hashable, Sendable {
    let path: ArchivePath
    let kind: ExamKind
    /// Image pages in reading order, or the PDF file(s).
    let fileURLs: [URL]

    var title: String { path.name ?? "" }
}

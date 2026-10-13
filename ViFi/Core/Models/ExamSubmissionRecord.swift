import Foundation

/// A submission as stored in Cloud Firestore `submissions/<id>` and read back by the moderation tools.
///
/// The counterpart of the write-side `ExamSubmission`: the archive path is flat denormalized text (no canonical
/// ids), the exam name and year are already folded into the single `exam` text, and each file is a reference to
/// a `pending/<uid>/…` object rather than raw bytes.
nonisolated struct ExamSubmissionRecord: Identifiable, Equatable, Sendable {
    let id: String
    let ownerId: String
    let university: String
    let faculty: String
    let department: String
    let lesson: String
    /// The exam's display text with the year folded in, e.g. "2023 VİZE".
    let exam: String
    let kind: ExamKind
    /// The moderation state: `pending`, `approved` or `rejected`.
    let status: String
    let createdAt: Date?
    let files: [SubmissionFileRef]

    /// The taxonomy location used to resolve the submission against the archive.
    var location: SubmissionLocation {
        SubmissionLocation(
            university: university, faculty: faculty, department: department, lesson: lesson, examText: exam
        )
    }
}

/// A reference to one stored file of a submission: its Storage object path and reading-order position.
nonisolated struct SubmissionFileRef: Equatable, Sendable {
    let storagePath: String
    let order: Int
}

/// Turns raw `submissions/<id>` documents into `ExamSubmissionRecord`s. Pure and Firestore-free (the `createdAt`
/// server timestamp is converted to a `Date` by the caller), so it is unit-tested with plain dictionaries.
nonisolated enum SubmissionRecordParser {
    /// The record for `id`/`data`, or `nil` when a required field is missing or malformed.
    static func record(id: String, data: [String: Any], createdAt: Date?) -> ExamSubmissionRecord? {
        guard let ownerId = data["ownerId"] as? String,
              let university = text(data["university"]),
              let faculty = text(data["faculty"]),
              let department = text(data["department"]),
              let lesson = text(data["lesson"]),
              let exam = text(data["exam"]),
              let kindRaw = data["kind"] as? String, let kind = ExamKind(rawValue: kindRaw),
              let status = data["status"] as? String, !status.isEmpty else {
            return nil
        }
        return ExamSubmissionRecord(
            id: id, ownerId: ownerId, university: university, faculty: faculty, department: department,
            lesson: lesson, exam: exam, kind: kind, status: status, createdAt: createdAt,
            files: files(from: data["files"])
        )
    }

    /// The file references with a non-empty `storagePath`, in `order` (stable for equal/absent orders).
    private static func files(from value: Any?) -> [SubmissionFileRef] {
        let entries = value as? [[String: Any]] ?? []
        return entries
            .enumerated()
            .compactMap { offset, entry -> (Int, SubmissionFileRef)? in
                guard let path = text(entry["storagePath"]) else { return nil }
                let order = entry["order"] as? Int ?? offset
                return (offset, SubmissionFileRef(storagePath: path, order: order))
            }
            .sorted { $0.1.order == $1.1.order ? $0.0 < $1.0 : $0.1.order < $1.1.order }
            .map(\.1)
    }

    /// A non-empty string, or `nil`.
    private static func text(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }
}

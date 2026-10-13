import Foundation

/// The server-ready form of an `ExamSubmission`: the exact field values written to Firestore
/// `submissions/<submissionId>` (every key except the server-stamped `createdAt`) together with the Cloud
/// Storage uploads.
///
/// Computed purely from an `ExamSubmission`, so the year folding, file naming and storage paths are unit-tested
/// without Firebase; the live service only adds `FieldValue.serverTimestamp()` and performs the I/O. The field
/// set and the 1…50-file list match `firestore.rules` (`submissions` whitelist) and `storage.rules`
/// (`pending/<uid>/<submissionId>/<fileName>`).
nonisolated struct ExamSubmissionPayload: Equatable, Sendable {
    /// The literal `status` value a submission is created with; the only value the create rule accepts.
    static let pendingStatus = "pending"

    let ownerId: String
    let university: String
    let faculty: String
    let department: String
    let lesson: String
    /// Free-typed exam name with the year folded in (the schema has no separate year field).
    let exam: String
    /// `"JPG"` or `"PDF"` — `ExamKind.rawValue`.
    let kind: String
    /// Always `pendingStatus` at creation.
    let status: String
    /// The files to upload, in order; each carries its storage path, content type and bytes.
    let files: [UploadFile]

    /// Builds the server-ready payload. `submissionId` is the Firestore document id, reused as the Storage
    /// folder name so the moderation tooling can correlate the document with its uploaded files. Files are
    /// emitted in ascending `order`, each named `<order>.<ext>` so names are unique within the submission and
    /// never collide with an existing object (the Storage rules reject overwrites).
    static func make(from submission: ExamSubmission, ownerId: String, submissionId: String) -> ExamSubmissionPayload {
        let kind = submission.kind
        let files = submission.files
            .sorted { $0.order < $1.order }
            .map { file -> UploadFile in
                let fileName = "\(file.order).\(kind.fileExtension)"
                return UploadFile(
                    storagePath: "pending/\(ownerId)/\(submissionId)/\(fileName)",
                    fileName: fileName,
                    order: file.order,
                    contentType: kind.uploadContentType,
                    data: file.data
                )
            }
        return ExamSubmissionPayload(
            ownerId: ownerId,
            university: submission.university,
            faculty: submission.faculty,
            department: submission.department,
            lesson: submission.lesson,
            exam: ExamSubmission.examText(name: submission.examName, year: submission.year),
            kind: kind.rawValue,
            status: pendingStatus,
            files: files
        )
    }

    /// The `files` array as the Firestore document stores it: `[{ storagePath, order }]`, ordered.
    var fileDocuments: [[String: Any]] {
        files.map { ["storagePath": $0.storagePath, "order": $0.order] }
    }

    /// The Firestore document's fields except the server-stamped `createdAt` — the nine non-timestamp keys of
    /// the ten-key `submissions` schema. The live service adds `createdAt` as a server timestamp before writing.
    var firestoreFields: [String: Any] {
        [
            "ownerId": ownerId,
            "university": university,
            "faculty": faculty,
            "department": department,
            "lesson": lesson,
            "exam": exam,
            "kind": kind,
            "status": status,
            "files": fileDocuments,
        ]
    }
}

/// One Cloud Storage upload of a submission.
nonisolated struct UploadFile: Equatable, Sendable {
    /// Full object path: `pending/<uid>/<submissionId>/<fileName>`.
    let storagePath: String
    let fileName: String
    /// 1-based position in reading order.
    let order: Int
    /// `"image/jpeg"` or `"application/pdf"`, as the Storage rules require.
    let contentType: String
    let data: Data
}

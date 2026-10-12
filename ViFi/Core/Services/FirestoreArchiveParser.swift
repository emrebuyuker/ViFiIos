import Foundation

/// Turns raw Cloud Firestore documents (`DocumentSnapshot.data()`) into archive models.
///
/// Pure and Firestore-free so it can be unit-tested with plain dictionaries, like `ArchiveParser` is for the
/// Realtime Database. The field names here are the read side of the contract the migration script (item #9)
/// writes to; keep the two in sync.
///
/// Firestore shape:
/// - `catalogNodes/{nodeId}`: `{ name, parentId, status, childCount, <ancestor ids> }` — one document per
///   university / faculty / department / course. A level is listed with `where(parentId == <node id>)`
///   (universities use `rootParentId`), filtered to `status == published`.
/// - `exams/{examId}`: `{ title, courseId, kind: "JPG"|"PDF", status, files: [{ storagePath, order }] }` — the
///   exams under a course, listed with `where(courseId == <course id>)`.
nonisolated enum FirestoreArchiveParser {
    enum Field {
        static let name = "name"
        static let title = "title"
        static let parentId = "parentId"
        static let courseId = "courseId"
        static let status = "status"
        static let childCount = "childCount"
        static let kind = "kind"
        static let files = "files"
        static let storagePath = "storagePath"
        static let order = "order"
    }

    /// Documents with this status are the published archive shown to users.
    static let publishedStatus = "published"
    /// `parentId` of a top-level (university) catalog node, so every level lists uniformly by `parentId`.
    static let rootParentId = ""

    /// The entries listed under `path`, built from the raw documents (`id` + `data()`) and sorted for display.
    /// `path.childLevel` decides whether the documents are catalog nodes or exams.
    static func items(from docs: [(id: String, data: [String: Any])], under path: ArchivePath) -> [ArchiveItem] {
        guard let childLevel = path.childLevel else { return [] }
        let items = docs.compactMap { doc -> ArchiveItem? in
            guard let displayName = displayName(from: doc.data, level: childLevel), !displayName.isEmpty else {
                return nil
            }
            let childPath = path.appending(id: doc.id, displayName: displayName)
            if childLevel == .exam {
                guard let summary = examSummary(from: doc.data) else { return nil }
                return ArchiveItem(path: childPath, level: .exam, childCount: nil, exam: summary)
            }
            return ArchiveItem(path: childPath, level: childLevel, childCount: childCount(from: doc.data), exam: nil)
        }
        return ArchiveParser.sorted(items, level: childLevel)
    }

    /// The exam document stored in `data`, or `nil` when it has no usable files.
    static func document(from data: [String: Any], at path: ArchivePath, bucket: String) -> ExamDocument? {
        guard let kind = examKind(from: data) else { return nil }
        let urls = fileURLs(from: data, bucket: bucket)
        guard !urls.isEmpty else { return nil }
        return ExamDocument(path: path, kind: kind, fileURLs: urls)
    }

    // MARK: - Helpers

    private static func displayName(from data: [String: Any], level: ArchiveLevel) -> String? {
        // Exams denormalise their display name as `title`; catalog nodes use `name`.
        (data[level == .exam ? Field.title : Field.name]) as? String
    }

    private static func childCount(from data: [String: Any]) -> Int? {
        guard let count = data[Field.childCount] as? Int else { return nil }
        return max(0, count)
    }

    private static func examKind(from data: [String: Any]) -> ExamKind? {
        guard let raw = data[Field.kind] as? String else { return nil }
        return ExamKind(rawValue: raw)
    }

    private static func examSummary(from data: [String: Any]) -> ExamSummary? {
        guard let kind = examKind(from: data) else { return nil }
        let count = fileEntries(from: data).count
        guard count > 0 else { return nil }
        return ExamSummary(kind: kind, fileCount: count)
    }

    /// The file entries with a non-empty `storagePath`, in `order` (stable for equal/absent orders).
    private static func fileEntries(from data: [String: Any]) -> [[String: Any]] {
        let files = data[Field.files] as? [[String: Any]] ?? []
        return files
            .filter { ($0[Field.storagePath] as? String)?.isEmpty == false }
            .enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element[Field.order] as? Int ?? lhs.offset
                let right = rhs.element[Field.order] as? Int ?? rhs.offset
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map(\.element)
    }

    private static func fileURLs(from data: [String: Any], bucket: String) -> [URL] {
        fileEntries(from: data).compactMap { entry in
            guard let storagePath = entry[Field.storagePath] as? String else { return nil }
            return StorageURL.canonical(storagePath: storagePath, bucket: bucket)
        }
    }
}

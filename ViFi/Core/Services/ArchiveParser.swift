import Foundation

/// Turns raw Realtime Database values (`DataSnapshot.value`) into archive models.
///
/// Pure and Firebase-free so it can be unit-tested with plain dictionaries.
///
/// Database shape:
/// ```
/// Universitiess/<university>/<faculty>/<department>/<lesson>/<exam>/<JPG|PDF>/<pushId>/downloadURL
/// ```
/// Every node also stores its own name as a string leaf (`uniname`, `fakname`, `bolname`,
/// `lessonname`, `imagename`). Real entries are always objects, so string leaves are skipped.
nonisolated enum ArchiveParser {
    /// The entries listed under the node at `path`, sorted for display.
    static func items(in value: Any?, at path: ArchivePath) -> [ArchiveItem] {
        guard let level = path.childLevel else { return [] }
        let items = objectEntries(of: value).map { name, child in
            ArchiveItem(
                path: path.appending(name),
                level: level,
                childCount: level == .exam ? nil : objectEntries(of: child).count,
                exam: level == .exam ? examSummary(in: child) : nil
            )
        }
        return sorted(items, level: level)
    }

    /// The document stored in an exam node, or `nil` when it has no files.
    ///
    /// When an exam has both kinds, images win (the legacy app opened them first).
    static func document(in value: Any?, at path: ArchivePath) -> ExamDocument? {
        let entries = dictionary(from: value)
        for kind in [ExamKind.images, .pdf] {
            let urls = fileURLs(in: entries[kind.rawValue])
            if !urls.isEmpty {
                return ExamDocument(path: path, kind: kind, fileURLs: urls)
            }
        }
        return nil
    }

    static func examSummary(in value: Any?) -> ExamSummary? {
        let entries = dictionary(from: value)
        for kind in [ExamKind.images, .pdf] {
            let count = fileURLs(in: entries[kind.rawValue]).count
            if count > 0 {
                return ExamSummary(kind: kind, fileCount: count)
            }
        }
        return nil
    }

    /// `downloadURL`s of a `JPG`/`PDF` node, in upload order (push ids sort chronologically;
    /// array-shaped nodes keep their numeric index order).
    static func fileURLs(in value: Any?) -> [URL] {
        dictionary(from: value)
            .sorted { lhs, rhs in
                if let left = Int(lhs.key), let right = Int(rhs.key) {
                    return left < right
                }
                return lhs.key < rhs.key
            }
            .compactMap { _, file in
                guard let string = dictionary(from: file)["downloadURL"] as? String else { return nil }
                return URL(string: string)
            }
    }

    /// Names are sorted in Turkish alphabetical order with numeric awareness ("2. Sınıf" < "10. Sınıf").
    /// Exams are listed newest first ("2019 FİNAL" before "2002 VİZE").
    static func sorted(_ items: [ArchiveItem], level: ArchiveLevel) -> [ArchiveItem] {
        let ascending = items.sorted { lhs, rhs in
            compare(lhs.name, rhs.name) == .orderedAscending
        }
        return level == .exam ? ascending.reversed() : ascending
    }

    /// Turkish alphabetical order (Ç after C, Ş after S…). `.diacriticInsensitive` is deliberately
    /// absent: it folds "Ç" into "C" inconsistently and makes the order depend on input order.
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(
            rhs,
            options: [.caseInsensitive, .numeric],
            range: nil,
            locale: Locale(identifier: "tr_TR")
        )
    }

    // MARK: - Helpers

    /// Child entries whose values are objects (real archive nodes).
    private static func objectEntries(of value: Any?) -> [(String, Any)] {
        dictionary(from: value).compactMap { key, child in
            dictionary(from: child).isEmpty ? nil : (key, child)
        }
    }

    /// Firebase returns arrays for nodes keyed `0, 1, 2…`; normalise both shapes to a dictionary.
    private static func dictionary(from value: Any?) -> [String: Any] {
        if let dictionary = value as? [String: Any] {
            return dictionary
        }
        if let array = value as? [Any] {
            var dictionary: [String: Any] = [:]
            for (index, element) in array.enumerated() where !(element is NSNull) {
                dictionary[String(index)] = element
            }
            return dictionary
        }
        return [:]
    }
}

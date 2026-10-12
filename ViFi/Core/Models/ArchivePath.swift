import Foundation

/// The levels of the exam archive, in drill-down order.
///
/// The raw value is the depth of a node of that level:
/// `Universitiess/<university>/<faculty>/<department>/<lesson>/<exam>`.
nonisolated enum ArchiveLevel: Int, CaseIterable, Codable, Sendable {
    case university = 1
    case faculty
    case department
    case lesson
    case exam
}

/// Position of a node in the archive tree, e.g. `[university, faculty, department]`.
///
/// Each level has a stable `id` (`components`) used for lookups, routing and identity, and a `displayName`
/// shown to the user. On the Realtime Database (name-keyed) the two are equal; under Firestore the ids are
/// canonical slugs while the display names stay human-readable. Equality and hashing use the ids alone, so
/// renaming a node never changes which navigation route or recents entry it is.
///
/// The root path (no components) is the university list.
nonisolated struct ArchivePath: Hashable, Codable, Sendable {
    /// Stable id of each level, root→leaf. Equal to the display names on the Realtime Database.
    let components: [String]
    /// Name shown for each level, root→leaf; always the same length as `components`.
    let displayNames: [String]

    static let root = ArchivePath(components: [])

    /// - Parameter displayNames: per-level display names; defaults to (and, on a length mismatch, falls back
    ///   to) `components`, which is correct while ids equal names.
    init(components: [String], displayNames: [String]? = nil) {
        self.components = components
        if let displayNames, displayNames.count == components.count {
            self.displayNames = displayNames
        } else {
            self.displayNames = components
        }
    }

    var depth: Int { components.count }

    var isRoot: Bool { components.isEmpty }

    /// Display name of the node this path points at (`nil` for the root).
    var displayName: String? { displayNames.last }

    /// Level of the node this path points at (`nil` for the root).
    var level: ArchiveLevel? { ArchiveLevel(rawValue: depth) }

    /// Level of the entries listed under this path (`nil` below exams).
    var childLevel: ArchiveLevel? { ArchiveLevel(rawValue: depth + 1) }

    var parent: ArchivePath? {
        isRoot ? nil : ArchivePath(components: Array(components.dropLast()), displayNames: Array(displayNames.dropLast()))
    }

    /// Appends a level whose id and display name are the same (Realtime Database, name-keyed).
    func appending(_ name: String) -> ArchivePath {
        appending(id: name, displayName: name)
    }

    /// Appends a level with a distinct stable id and display name (Firestore).
    func appending(id: String, displayName: String) -> ArchivePath {
        ArchivePath(components: components + [id], displayNames: displayNames + [displayName])
    }

    /// The ancestor made of the first `count` levels.
    func prefix(_ count: Int) -> ArchivePath {
        ArchivePath(components: Array(components.prefix(count)), displayNames: Array(displayNames.prefix(count)))
    }

    // Identity is the ids alone; display names never affect equality or hashing.
    static func == (lhs: ArchivePath, rhs: ArchivePath) -> Bool {
        lhs.components == rhs.components
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(components)
    }

    private enum CodingKeys: String, CodingKey {
        case components, displayNames
    }

    /// Decodes display names when present; a path stored before they existed keeps working with ids as names.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            components: try container.decode([String].self, forKey: .components),
            displayNames: try container.decodeIfPresent([String].self, forKey: .displayNames)
        )
    }
}

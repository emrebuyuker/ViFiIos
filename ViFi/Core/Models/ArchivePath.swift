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
/// The root path (no components) is the university list.
nonisolated struct ArchivePath: Hashable, Codable, Sendable {
    let components: [String]

    static let root = ArchivePath(components: [])

    init(components: [String]) {
        self.components = components
    }

    var depth: Int { components.count }

    var isRoot: Bool { components.isEmpty }

    /// Display name of the node this path points at (`nil` for the root).
    var name: String? { components.last }

    /// Level of the node this path points at (`nil` for the root).
    var level: ArchiveLevel? { ArchiveLevel(rawValue: depth) }

    /// Level of the entries listed under this path (`nil` below exams).
    var childLevel: ArchiveLevel? { ArchiveLevel(rawValue: depth + 1) }

    var parent: ArchivePath? {
        isRoot ? nil : ArchivePath(components: Array(components.dropLast()))
    }

    func appending(_ name: String) -> ArchivePath {
        ArchivePath(components: components + [name])
    }

    /// The ancestor made of the first `count` components.
    func prefix(_ count: Int) -> ArchivePath {
        ArchivePath(components: Array(components.prefix(count)))
    }
}

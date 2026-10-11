import Foundation
import os

/// One entry of a bundled list: a stable canonical `id` (used for notification segments / FCM topics) and the
/// `name` shown to the user.
nonisolated struct CatalogItem: Hashable, Codable, Sendable, Identifiable {
    let id: String
    let name: String
}

/// The bundled lists of Turkish universities, faculties and departments that back the profile pickers.
///
/// Each entry carries a canonical id so a picked value can be targeted by notification segments regardless of
/// casing or spelling. The pickers always allow free text (slugged best-effort), so a missing or incomplete
/// list only degrades convenience, never blocks the user. Filtering is unit-testable (plain value type).
nonisolated struct UniversityCatalog: Sendable {
    let universities: [CatalogItem]
    let faculties: [CatalogItem]
    let departments: [CatalogItem]

    /// Universities whose name contains `query` (Turkish-insensitive); the whole list when the query is blank.
    func universities(matching query: String) -> [CatalogItem] {
        Self.filtered(universities, matching: query)
    }

    /// Faculties whose name contains `query` (Turkish-insensitive); the whole list when the query is blank.
    func faculties(matching query: String) -> [CatalogItem] {
        Self.filtered(faculties, matching: query)
    }

    /// Departments whose name contains `query` (Turkish-insensitive); the whole list when the query is blank.
    func departments(matching query: String) -> [CatalogItem] {
        Self.filtered(departments, matching: query)
    }

    /// Items whose name contains `query`, matched case- and diacritic-insensitively with Turkish casing (so
    /// "isl" finds "İşletme" and "bogazici" finds "Boğaziçi"); the whole list when the query is blank.
    static func filtered(_ items: [CatalogItem], matching query: String) -> [CatalogItem] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return items }
        return items.filter { normalized($0.name).contains(needle) }
    }

    private static let turkish = Locale(identifier: "tr_TR")

    private static func normalized(_ string: String) -> String {
        string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: turkish)
            .folding(options: .diacriticInsensitive, locale: turkish)
    }
}

extension UniversityCatalog {
    /// The lists bundled with the app, sorted by name. Empty lists when a resource is missing or malformed
    /// (the pickers then fall back to free text), logged.
    static func bundled(bundle: Bundle = .main) -> UniversityCatalog {
        UniversityCatalog(
            universities: load("turkish-universities", from: bundle),
            faculties: load("turkish-faculties", from: bundle),
            departments: load("turkish-departments", from: bundle)
        )
    }

    private static func load(_ name: String, from bundle: Bundle) -> [CatalogItem] {
        guard let url = bundle.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([CatalogItem].self, from: data) else {
            Logger.app.error("Profile catalog resource \(name, privacy: .public).json is missing or invalid")
            return []
        }
        return items.sorted { ArchiveParser.compare($0.name, $1.name) == .orderedAscending }
    }
}

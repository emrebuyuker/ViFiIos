import Foundation
import Testing
@testable import ViFi

@Suite("UniversityCatalog")
struct UniversityCatalogTests {
    private let catalog = UniversityCatalog(
        universities: [
            CatalogItem(id: "bogazici-universitesi", name: "Boğaziçi Üniversitesi"),
            CatalogItem(id: "ege-universitesi", name: "Ege Üniversitesi"),
            CatalogItem(id: "istanbul-teknik-universitesi", name: "İstanbul Teknik Üniversitesi"),
        ],
        faculties: [
            CatalogItem(id: "muhendislik-fakultesi", name: "Mühendislik Fakültesi"),
            CatalogItem(id: "tip-fakultesi", name: "Tıp Fakültesi"),
        ],
        departments: [
            CatalogItem(id: "bilgisayar-muhendisligi", name: "Bilgisayar Mühendisliği"),
            CatalogItem(id: "isletme", name: "İşletme"),
        ]
    )

    @Test("A blank query returns the whole list")
    func blankQueryReturnsAll() {
        #expect(catalog.universities(matching: "   ").count == 3)
        #expect(catalog.faculties(matching: "").count == 2)
        #expect(catalog.departments(matching: "").count == 2)
    }

    @Test("Filtering matches on name, ignoring case and Turkish diacritics (including dotted İ)")
    func filtersInsensitively() {
        #expect(catalog.universities(matching: "bogazici").map(\.id) == ["bogazici-universitesi"])
        #expect(catalog.universities(matching: "EGE").map(\.id) == ["ege-universitesi"])
        // A dotless-i query still reaches the dotted-İ entry.
        #expect(catalog.departments(matching: "isletme").map(\.id) == ["isletme"])
    }

    @Test("A query with no match returns an empty list")
    func noMatchIsEmpty() {
        #expect(catalog.universities(matching: "zzz").isEmpty)
    }

    @Test("The bundled catalog loads its resources from the app bundle with ids")
    func bundledLoadsResources() {
        let bundled = UniversityCatalog.bundled()
        #expect(!bundled.universities.isEmpty, "turkish-universities.json should be bundled")
        #expect(!bundled.faculties.isEmpty, "turkish-faculties.json should be bundled")
        #expect(!bundled.departments.isEmpty, "turkish-departments.json should be bundled")
        // Ids are lowercase slugs.
        #expect(bundled.universities.allSatisfy { $0.id.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil })
        // Sakarya is on the list with the expected canonical id.
        #expect(bundled.universities.contains { $0.id == "sakarya-universitesi" })
    }
}

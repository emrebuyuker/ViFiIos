import Foundation
import Testing
@testable import ViFi

@Suite("Slug")
struct SlugTests {
    @Test("Turkish names become lowercase ASCII slugs (matching the bundled catalog ids)", arguments: [
        ("Sakarya Üniversitesi", "sakarya-universitesi"),
        ("Boğaziçi Üniversitesi", "bogazici-universitesi"),
        ("İstanbul Teknik Üniversitesi", "istanbul-teknik-universitesi"),
        ("İşletme", "isletme"),
        ("Mühendislik-Mimarlık Fakültesi", "muhendislik-mimarlik-fakultesi"),
        ("Fen-Edebiyat Fakültesi", "fen-edebiyat-fakultesi"),
        ("Çaycuma", "caycuma"),
    ])
    func slugsTurkishNames(_ input: String, _ expected: String) {
        #expect(Slug.make(input) == expected)
    }

    @Test("Separators collapse and do not lead or trail")
    func collapsesSeparators() {
        #expect(Slug.make("  Boş   Köy  ") == "bos-koy")
        #expect(Slug.make("A, B & C") == "a-b-c")
        #expect(Slug.make("---x---") == "x")
    }

    @Test("A value with no usable characters falls back to a placeholder")
    func emptyFallsBack() {
        #expect(Slug.make("") == "unknown")
        #expect(Slug.make("   ") == "unknown")
        #expect(Slug.make("...") == "unknown")
    }
}

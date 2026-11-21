import Foundation
import Testing
@testable import ViFi

/// `CatalogName` and the recent-exam "Sorular" flag (4.2.0). Name cases match `CATALOG_NAME_CASES` in
/// firebase/tests/conversionSchema.test.mjs.
@Suite("Catalog name")
struct CatalogNameTests {
    nonisolated static let cases: [(input: String, expected: String)] = [
        ("Güç elektroniği devreleri", "GÜÇ ELEKTRONİĞİ DEVRELERİ"),
        ("Eskişehir Teknik Üniversitesi", "ESKİŞEHİR TEKNİK ÜNİVERSİTESİ"),
        ("ılık işlem", "ILIK İŞLEM"),
        ("  Fen   Edebiyat Fakültesi ", "FEN EDEBİYAT FAKÜLTESİ"),
        ("MATEMATİK BÖLÜMÜ", "MATEMATİK BÖLÜMÜ"),
        ("Fizik 2", "FİZİK 2")
    ]

    @Test("Each shared case matches the server", arguments: Self.cases.indices)
    func sharedCase(index: Int) {
        let (input, expected) = Self.cases[index]
        #expect(CatalogName.display(input) == expected)
        #expect(CatalogName.display(expected) == expected)
    }

    @MainActor
    @Test("A recent exam keeps whether it opened on the question screen; older entries decode as file exams")
    func recentStructuredFlag() throws {
        let defaults = try #require(UserDefaults(suiteName: "CatalogNameTests.\(UUID().uuidString)"))
        let store = RecentExamsStore(defaults: defaults)
        let path = ArchivePath(components: ["u", "f", "d", "c", "2017 FİNAL"])
        store.record(path: path, kind: .images, isStructured: true)
        #expect(RecentExamsStore(defaults: defaults).exams.first?.isStructured == true)

        let encodedPath = try #require(String(bytes: try JSONEncoder().encode(path), encoding: .utf8))
        let legacy = Data(#"[{"path":\#(encodedPath),"kind":"JPG","openedAt":0}]"#.utf8)
        defaults.set(legacy, forKey: "recentExams.v1")
        let reloaded = RecentExamsStore(defaults: defaults).exams
        #expect(reloaded.count == 1)
        #expect(reloaded.first?.isStructured == nil)
    }
}

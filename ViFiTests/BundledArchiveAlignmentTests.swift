import Foundation
import Testing
@testable import ViFi

/// The bundled profile lists must carry the archive's universities, faculties and departments under names the
/// course resolver (`ArchiveNameMatch`) matches — otherwise a student who picks their school from the list
/// gets no courses in "Sınav Ekle". Guards the manual alignment of the bundled JSON to the archive taxonomy.
@Suite("Bundled ↔ archive alignment")
struct BundledArchiveAlignmentTests {
    private static let catalog = UniversityCatalog.bundled()

    @Test("Each archive university has a matching bundled university", arguments: [
        "BOZOK ÜNİVERSİTESİ",
        "BÜLENT ECEVİT ÜNİVERSİTESİ",
        "KOCAELİ ÜNİVERSİTESİ",
        "KÜTAHYA DUMLUPINAR ÜNİVERSİTESİ",
        "SAKARYA ÜNİVERSİTESİ",
    ])
    func universityMatches(archiveName: String) {
        #expect(Self.catalog.universities.contains { ArchiveNameMatch.matches($0.name, archiveName) })
    }

    @Test("Each archive faculty has a matching bundled faculty", arguments: [
        "MÜHENDİSLİK MİMARLIK FAKÜLTESİ",
        "FEN EDEBİYAT FAKÜLTESİ",
        "MÜHENDİSLİK FAKÜLTESİ",
        "BİLGİSAYAR VE BİLİŞİM BİLİMLERİ FAKÜLTESİ",
    ])
    func facultyMatches(archiveName: String) {
        #expect(Self.catalog.faculties.contains { ArchiveNameMatch.matches($0.name, archiveName) })
    }

    @Test("Each archive department has a matching bundled department", arguments: [
        "BİLGİSAYAR MÜHENDİSLİĞİ",
        "MATEMATİK BÖLÜMÜ",
        "İNŞAAT MÜHENDİSLİĞİ",
        "ELEKTRİK ELEKTRONİK MÜHENDİSLİĞİ",
        "MAKİNE MÜHENDİSLİĞİ",
    ])
    func departmentMatches(archiveName: String) {
        #expect(Self.catalog.departments.contains {
            ArchiveNameMatch.matchesDepartment(archive: archiveName, profile: $0.name)
        })
    }
}

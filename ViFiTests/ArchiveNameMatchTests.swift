import Foundation
import Testing
@testable import ViFi

@Suite("ArchiveNameMatch")
struct ArchiveNameMatchTests {
    @Test("Matching folds case, diacritics and dotless i, so a bundled name finds its archive node", arguments: [
        ("Boğaziçi Üniversitesi", "BOĞAZİÇİ ÜNİVERSİTESİ"),
        ("İşletme", "isletme"),
        ("Bilgisayar Mühendisliği", "BİLGİSAYAR MÜHENDİSLİĞİ"),
        ("Kütahya Dumlupınar", "KÜTAHYA DUMLUPINAR"),
    ])
    func matches(lhs: String, rhs: String) {
        #expect(ArchiveNameMatch.matches(lhs, rhs))
    }

    @Test("Different names do not match", arguments: [
        ("Boğaziçi Üniversitesi", "Bozok Üniversitesi"),
        ("Matematik", "Fizik"),
    ])
    func doesNotMatch(lhs: String, rhs: String) {
        #expect(!ArchiveNameMatch.matches(lhs, rhs))
    }

    @Test("Contains is a folded substring match for search", arguments: [
        ("AYRIK İŞLEMSEL YAPILAR", "ayrık", true),
        ("AYRIK İŞLEMSEL YAPILAR", "işlemsel", true),
        ("AYRIK İŞLEMSEL YAPILAR", "fizik", false),
    ])
    func contains(haystack: String, needle: String, expected: Bool) {
        #expect(ArchiveNameMatch.contains(haystack, needle) == expected)
    }

    @Test("Department matching tolerates the archive's BÖLÜMÜ suffix but not a distinct word", arguments: [
        ("MATEMATİK BÖLÜMÜ", "Matematik", true),
        ("MATEMATİK BÖLÜM", "Matematik", true),
        ("BİLGİSAYAR MÜHENDİSLİĞİ", "Bilgisayar Mühendisliği", true),
        ("MATEMATİK MÜHENDİSLİĞİ", "Matematik", false),
        ("FİZİK BÖLÜMÜ", "Matematik", false),
    ])
    func matchesDepartment(archive: String, profile: String, expected: Bool) {
        #expect(ArchiveNameMatch.matchesDepartment(archive: archive, profile: profile) == expected)
    }
}

import Foundation
import Testing
@testable import ViFi

@Suite("ArchivePath")
struct ArchivePathTests {
    private let lesson = Fixture.lesson

    @Test("The root path is the university list")
    func root() {
        let root = ArchivePath.root

        #expect(root.isRoot)
        #expect(root.depth == 0)
        #expect(root.displayName == nil)
        #expect(root.displayNames.isEmpty)
        #expect(root.level == nil)
        #expect(root.childLevel == .university)
        #expect(root.parent == nil)
    }

    @Test("A path's depth is the raw value of its level", arguments: ArchiveLevel.allCases)
    func levelMatchesDepth(_ level: ArchiveLevel) {
        let path = ArchivePath(components: (1...level.rawValue).map { "Düğüm \($0)" })

        #expect(!path.isRoot)
        #expect(path.depth == level.rawValue)
        #expect(path.level == level)
        #expect(path.childLevel == ArchiveLevel(rawValue: level.rawValue + 1))
    }

    @Test("Nothing is listed below an exam")
    func examHasNoChildLevel() {
        #expect(Fixture.imagesExam.level == .exam)
        #expect(Fixture.imagesExam.childLevel == nil)
    }

    @Test("The display name is the last level's name")
    func displayName() {
        #expect(lesson.displayName == "MÜHENDİSLİK MATEMATİĞİ")
        #expect(Fixture.imagesExam.displayName == "2019 FİNAL")
    }

    @Test("Without explicit display names, the ids are used as the display names")
    func displayNamesDefaultToIds() {
        #expect(lesson.displayNames == lesson.components)
        #expect(lesson.displayName == lesson.components.last)
    }

    @Test("A distinct id and display name are carried per level and sliced together")
    func idAndDisplayNameAreSeparate() {
        let root = ArchivePath.root
        let university = root.appending(id: "bogazici-universitesi", displayName: "Boğaziçi Üniversitesi")
        let faculty = university.appending(id: "muhendislik-fakultesi", displayName: "Mühendislik Fakültesi")

        #expect(faculty.components == ["bogazici-universitesi", "muhendislik-fakultesi"])
        #expect(faculty.displayNames == ["Boğaziçi Üniversitesi", "Mühendislik Fakültesi"])
        #expect(faculty.displayName == "Mühendislik Fakültesi")
        // parent and prefix slice the display names alongside the ids.
        #expect(faculty.parent?.displayNames == ["Boğaziçi Üniversitesi"])
        #expect(faculty.prefix(1).displayNames == ["Boğaziçi Üniversitesi"])
    }

    @Test("Identity is the ids alone; display names do not affect equality or hashing")
    func equalityIgnoresDisplayNames() {
        let byId = ArchivePath(components: ["bogazici-universitesi"], displayNames: ["Boğaziçi Üniversitesi"])
        let renamed = ArchivePath(components: ["bogazici-universitesi"], displayNames: ["BOĞAZİÇİ ÜNİVERSİTESİ"])

        #expect(byId == renamed)
        #expect(Set([byId, renamed]).count == 1)
    }

    @Test("A mismatched display-name count falls back to the ids")
    func mismatchedDisplayNamesFallBack() {
        let path = ArchivePath(components: ["a", "b"], displayNames: ["only-one"])

        #expect(path.displayNames == ["a", "b"])
    }

    @Test("appending adds a child and parent removes it")
    func appendingAndParent() {
        let exam = lesson.appending("2019 FİNAL")

        #expect(exam.components == lesson.components + ["2019 FİNAL"])
        #expect(exam.parent == lesson)
        #expect(ArchivePath(components: ["BOZOK ÜNİVERSİTESİ"]).parent == .root)
    }

    @Test("prefix returns the ancestor at that depth", arguments: 0...4)
    func prefix(_ depth: Int) {
        let ancestor = lesson.prefix(depth)

        #expect(ancestor.depth == depth)
        #expect(ancestor.components == Array(lesson.components.prefix(depth)))
        #expect(ancestor.isRoot == (depth == 0))
    }

    @Test("prefix past the depth returns the path itself")
    func prefixPastDepth() {
        #expect(lesson.prefix(lesson.depth + 3) == lesson)
    }

    @Test("Paths with the same components are equal and hash alike")
    func equalityAndHashing() {
        let copy = ArchivePath(components: lesson.components)

        #expect(copy == lesson)
        #expect(Set([lesson, copy, Fixture.imagesExam]).count == 2)
        #expect(lesson != Fixture.imagesExam)
    }

    @Test("A path survives a Codable round trip, keeping its display names")
    func codableRoundTrip() throws {
        let path = ArchivePath(components: ["bogazici-universitesi"], displayNames: ["Boğaziçi Üniversitesi"])

        let decoded = try JSONDecoder().decode(ArchivePath.self, from: JSONEncoder().encode(path))

        #expect(decoded == path)
        #expect(decoded.displayNames == ["Boğaziçi Üniversitesi"])
    }

    @Test("A path stored before display names existed decodes with the ids as names")
    func decodesLegacyPathWithoutDisplayNames() throws {
        // A recents entry written by an older build: only `components`, no `displayNames`.
        let legacy = Data(#"{"components":["BOZOK ÜNİVERSİTESİ","2019 FİNAL"]}"#.utf8)

        let decoded = try JSONDecoder().decode(ArchivePath.self, from: legacy)

        #expect(decoded.components == ["BOZOK ÜNİVERSİTESİ", "2019 FİNAL"])
        #expect(decoded.displayNames == ["BOZOK ÜNİVERSİTESİ", "2019 FİNAL"])
    }
}

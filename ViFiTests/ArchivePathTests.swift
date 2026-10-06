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
        #expect(root.name == nil)
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

    @Test("The name is the last component")
    func name() {
        #expect(lesson.name == "MÜHENDİSLİK MATEMATİĞİ")
        #expect(Fixture.imagesExam.name == "2019 FİNAL")
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

    @Test("A path survives a Codable round trip")
    func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(Fixture.imagesExam)

        #expect(try JSONDecoder().decode(ArchivePath.self, from: data) == Fixture.imagesExam)
    }
}

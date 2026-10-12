import Foundation
import Testing
@testable import ViFi

@Suite("FirestoreArchiveParser")
struct FirestoreArchiveParserTests {
    private static let bucket = "vifi-831a8.appspot.com"
    /// A course path (depth 4): its children are exams.
    private let course = ArchivePath(
        components: ["bozok-universitesi", "muh-fak", "bilg-muh", "muh-mat"],
        displayNames: ["BOZOK ÜNİVERSİTESİ", "MÜHENDİSLİK FAKÜLTESİ", "BİLGİSAYAR MÜHENDİSLİĞİ", "MÜHENDİSLİK MATEMATİĞİ"]
    )

    // MARK: - Catalog levels

    @Test("Catalog nodes become sorted items carrying id, display name and child count")
    func catalogItems() {
        let docs: [(id: String, data: [String: Any])] = [
            node("kocaeli-universitesi", name: "KOCAELİ ÜNİVERSİTESİ", childCount: 2),
            node("bozok-universitesi", name: "BOZOK ÜNİVERSİTESİ", childCount: 3),
        ]

        let items = FirestoreArchiveParser.items(from: docs, under: .root)

        // Turkish sort: "BOZOK" before "KOCAELİ".
        #expect(items.map(\.name) == ["BOZOK ÜNİVERSİTESİ", "KOCAELİ ÜNİVERSİTESİ"])
        #expect(items.allSatisfy { $0.level == .university && $0.exam == nil })
        #expect(items.first?.childCount == 3)
        #expect(items.first?.path.components == ["bozok-universitesi"])
        #expect(items.first?.path.displayName == "BOZOK ÜNİVERSİTESİ")
    }

    @Test("A deeper level appends the child id and name to the parent path")
    func deeperLevelPaths() {
        let university = ArchivePath(components: ["bozok-universitesi"], displayNames: ["BOZOK ÜNİVERSİTESİ"])
        let docs = [node("muh-fak", name: "MÜHENDİSLİK FAKÜLTESİ", childCount: 4)]

        let items = FirestoreArchiveParser.items(from: docs, under: university)

        #expect(items.first?.level == .faculty)
        #expect(items.first?.path.components == ["bozok-universitesi", "muh-fak"])
        #expect(items.first?.path.displayNames == ["BOZOK ÜNİVERSİTESİ", "MÜHENDİSLİK FAKÜLTESİ"])
    }

    @Test("A node without a name is skipped")
    func nodeWithoutNameSkipped() {
        let docs: [(id: String, data: [String: Any])] = [
            ("no-name", ["childCount": 1]),
            node("ok", name: "ODTÜ", childCount: 1),
        ]

        let items = FirestoreArchiveParser.items(from: docs, under: .root)

        #expect(items.map(\.name) == ["ODTÜ"])
    }

    // MARK: - Exams

    @Test("Exam documents become exam items, newest first, with a file summary and no child count")
    func examItems() {
        let docs = [
            examNode("2018-vize", title: "2018 VİZE", kind: "PDF", fileCount: 1),
            examNode("2019-final", title: "2019 FİNAL", kind: "JPG", fileCount: 3),
        ]

        let items = FirestoreArchiveParser.items(from: docs, under: course)

        #expect(items.map(\.name) == ["2019 FİNAL", "2018 VİZE"])
        #expect(items.map(\.childCount) == [nil, nil])
        #expect(items.first?.exam == ExamSummary(kind: .images, fileCount: 3))
        #expect(items.last?.exam == ExamSummary(kind: .pdf, fileCount: 1))
        #expect(items.first?.path.components == course.components + ["2019-final"])
        #expect(items.first?.path.displayName == "2019 FİNAL")
    }

    @Test("An exam with no usable files is skipped in a listing")
    func examWithoutFilesSkipped() {
        let docs = [
            ("empty", ["title": "BOŞ", "kind": "JPG", "files": []] as [String: Any]),
            examNode("ok", title: "2020 FİNAL", kind: "JPG", fileCount: 1),
        ]

        let items = FirestoreArchiveParser.items(from: docs, under: course)

        #expect(items.map(\.name) == ["2020 FİNAL"])
    }

    // MARK: - Document

    @Test("A document builds its file URLs from storage paths, ordered by `order`")
    func documentFileURLs() throws {
        let examPath = course.appending(id: "2019-final", displayName: "2019 FİNAL")
        let data: [String: Any] = [
            "title": "2019 FİNAL",
            "kind": "JPG",
            "files": [
                ["storagePath": "imagess/b.jpg", "order": 1],
                ["storagePath": "imagess/a.jpg", "order": 0],
            ],
        ]

        let document = try #require(FirestoreArchiveParser.document(from: data, at: examPath, bucket: Self.bucket))

        #expect(document.kind == .images)
        #expect(document.title == "2019 FİNAL")
        #expect(document.fileURLs == [
            StorageURL.canonical(storagePath: "imagess/a.jpg", bucket: Self.bucket),
            StorageURL.canonical(storagePath: "imagess/b.jpg", bucket: Self.bucket),
        ].compactMap { $0 })
    }

    @Test("A document with no files or an unknown kind is nil")
    func unusableDocumentIsNil() {
        let examPath = course.appending(id: "x", displayName: "X")

        #expect(FirestoreArchiveParser.document(from: ["kind": "JPG", "files": []], at: examPath, bucket: Self.bucket) == nil)
        #expect(FirestoreArchiveParser.document(from: ["kind": "GIF", "files": [["storagePath": "imagess/a.jpg"]]], at: examPath, bucket: Self.bucket) == nil)
        #expect(FirestoreArchiveParser.document(from: [:], at: examPath, bucket: Self.bucket) == nil)
    }

    @Test("Files with an empty storage path are dropped")
    func emptyStoragePathDropped() throws {
        let examPath = course.appending(id: "x", displayName: "X")
        let data: [String: Any] = [
            "title": "X",
            "kind": "PDF",
            "files": [["storagePath": ""], ["storagePath": "pdfs/a.pdf", "order": 0]],
        ]

        let document = try #require(FirestoreArchiveParser.document(from: data, at: examPath, bucket: Self.bucket))

        #expect(document.fileURLs == [StorageURL.canonical(storagePath: "pdfs/a.pdf", bucket: Self.bucket)].compactMap { $0 })
    }

    // MARK: - Helpers

    private func node(_ id: String, name: String, childCount: Int) -> (id: String, data: [String: Any]) {
        (id, ["name": name, "childCount": childCount, "status": "published"])
    }

    private func examNode(_ id: String, title: String, kind: String, fileCount: Int) -> (id: String, data: [String: Any]) {
        let files = (0..<fileCount).map { ["storagePath": "imagess/\(id)-\($0).jpg", "order": $0] as [String: Any] }
        return (id, ["title": title, "kind": kind, "files": files, "status": "published"])
    }
}

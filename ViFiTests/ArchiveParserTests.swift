import Foundation
import Testing
@testable import ViFi

@Suite("ArchiveParser")
struct ArchiveParserTests {
    // MARK: - Entries

    @Test("Name placeholders and other leaves are skipped; only object nodes are entries")
    func skipsLeaves() {
        let raw: [String: Any] = [
            "BOZOK ÜNİVERSİTESİ": Raw.node("uniname", "BOZOK ÜNİVERSİTESİ"),
            "uniname": "Universitiess",
            "revision": 7,
            "isPublished": true,
            "draft": [String: Any](),
        ]

        let items = ArchiveParser.items(in: raw, at: .root)

        #expect(items.map(\.name) == ["BOZOK ÜNİVERSİTESİ"])
        #expect(items.map(\.path) == [ArchivePath(components: ["BOZOK ÜNİVERSİTESİ"])])
        #expect(items.map(\.level) == [.university])
        #expect(items.map(\.exam) == [nil])
    }

    @Test("Child counts include object nodes only")
    func childCounts() {
        let raw: [String: Any] = [
            "BOZOK ÜNİVERSİTESİ": Raw.node("uniname", "BOZOK ÜNİVERSİTESİ", children: [
                "MÜHENDİSLİK MİMARLIK FAKÜLTESİ": Raw.node("fakname", "MÜHENDİSLİK MİMARLIK FAKÜLTESİ"),
                "FEN EDEBİYAT FAKÜLTESİ": Raw.node("fakname", "FEN EDEBİYAT FAKÜLTESİ"),
            ]),
            "KOCAELİ ÜNİVERSİTESİ": Raw.node("uniname", "KOCAELİ ÜNİVERSİTESİ"),
        ]

        let items = ArchiveParser.items(in: raw, at: .root)

        #expect(items.map(\.name) == ["BOZOK ÜNİVERSİTESİ", "KOCAELİ ÜNİVERSİTESİ"])
        #expect(items.map(\.childCount) == [2, 0])
    }

    @Test("Entries below a node extend its path and take the next level")
    func nestedEntries() {
        let faculty = ArchivePath(components: ["BOZOK ÜNİVERSİTESİ", "MÜHENDİSLİK MİMARLIK FAKÜLTESİ"])
        let raw = Raw.node("fakname", "MÜHENDİSLİK MİMARLIK FAKÜLTESİ", children: [
            "BİLGİSAYAR MÜHENDİSLİĞİ": Raw.node("bolname", "BİLGİSAYAR MÜHENDİSLİĞİ", children: [
                "MÜHENDİSLİK MATEMATİĞİ": Raw.node("lessonname", "MÜHENDİSLİK MATEMATİĞİ"),
            ]),
        ])

        let items = ArchiveParser.items(in: raw, at: faculty)

        #expect(items.map(\.path) == [faculty.appending("BİLGİSAYAR MÜHENDİSLİĞİ")])
        #expect(items.map(\.level) == [.department])
        #expect(items.map(\.childCount) == [1])
    }

    @Test("Exams carry a summary of their files and no child count")
    func examEntries() {
        let raw: [String: Any] = [
            "2019 FİNAL": Raw.exam("2019 FİNAL", jpg: Raw.pages(3)),
            "2018 VİZE": Raw.exam("2018 VİZE", pdf: Raw.pdfs(1)),
            "2017 BÜTÜNLEME": Raw.exam("2017 BÜTÜNLEME", jpg: Raw.pages(2), pdf: Raw.pdfs(1)),
            "2021 VİZE": Raw.exam("2021 VİZE"),
        ]

        let items = ArchiveParser.items(in: raw, at: Fixture.lesson)

        #expect(items.map(\.name) == ["2021 VİZE", "2019 FİNAL", "2018 VİZE", "2017 BÜTÜNLEME"])
        #expect(items.allSatisfy { $0.level == .exam && $0.childCount == nil })
        #expect(items.map(\.exam) == [
            nil,
            ExamSummary(kind: .images, fileCount: 3),
            ExamSummary(kind: .pdf, fileCount: 1),
            ExamSummary(kind: .images, fileCount: 2),
        ])
    }

    @Test("Nothing is listed below an exam")
    func nothingBelowExams() {
        let raw = Raw.exam("2019 FİNAL", jpg: Raw.pages(3))

        #expect(ArchiveParser.items(in: raw, at: Fixture.imagesExam).isEmpty)
    }

    @Test("Missing, empty and leaf values have no entries or files", arguments: RawValueCase.allCases)
    func emptyValues(_ testCase: RawValueCase) {
        let value = testCase.value

        #expect(ArchiveParser.items(in: value, at: .root).isEmpty)
        #expect(ArchiveParser.document(in: value, at: Fixture.imagesExam) == nil)
        #expect(ArchiveParser.examSummary(in: value) == nil)
        #expect(ArchiveParser.fileURLs(in: value).isEmpty)
    }

    // MARK: - Exam files

    @Test("Images take precedence over PDFs")
    func imagesBeforePDF() throws {
        let raw = Raw.exam("2017 BÜTÜNLEME", jpg: Raw.pages(2), pdf: Raw.pdfs(1))

        #expect(ArchiveParser.examSummary(in: raw) == ExamSummary(kind: .images, fileCount: 2))
        let document = try #require(ArchiveParser.document(in: raw, at: Fixture.imagesExam))
        #expect(document.kind == .images)
        #expect(document.fileURLs.map(\.absoluteString) == Raw.pages(2))
    }

    @Test("PDFs are used when the image node has no usable files")
    func pdfWhenImagesAreUnusable() throws {
        let raw: [String: Any] = [
            "imagename": "2018 VİZE",
            "JPG": ["-Nf3k9Xq1000": ["downloadURL": 404] as [String: Any]],
            "PDF": Raw.uploads(Raw.pdfs(1)),
        ]

        let expected = ExamDocument(path: Fixture.pdfExam, kind: .pdf, fileURLs: try Raw.urls(Raw.pdfs(1)))

        #expect(ArchiveParser.examSummary(in: raw) == ExamSummary(kind: .pdf, fileCount: 1))
        #expect(ArchiveParser.document(in: raw, at: Fixture.pdfExam) == expected)
    }

    @Test("An exam node with only its name placeholder has no document")
    func examWithoutFiles() {
        let raw = Raw.exam("2021 VİZE")

        #expect(ArchiveParser.examSummary(in: raw) == nil)
        #expect(ArchiveParser.document(in: raw, at: Fixture.lesson.appending("2021 VİZE")) == nil)
    }

    @Test("Files are listed in upload order, i.e. by push id")
    func uploadOrder() {
        // Push ids sort by code point ("0" < "9" < "A" < "_" < "a"), which is their chronological order.
        let uploads: [String: Any] = [
            "-NfaQ": Raw.file(Raw.page(5)),
            "-NfAQ": Raw.file(Raw.page(3)),
            "-Nf9Q": Raw.file(Raw.page(2)),
            "-Nf_Q": Raw.file(Raw.page(4)),
            "-Nf0Q": Raw.file(Raw.page(1)),
        ]

        let urls = ArchiveParser.fileURLs(in: uploads)

        #expect(urls.map(\.absoluteString) == Raw.pages(5))
    }

    @Test("Uploads without a usable download URL are skipped")
    func unusableUploads() {
        let uploads: [String: Any] = [
            "-Nf3k9Xq1000": Raw.file(Raw.page(1)),
            "-Nf3k9Xq1001": ["downloadURL": 42] as [String: Any],
            "-Nf3k9Xq1002": ["fileName": "sayfa-2.jpg"],
            "-Nf3k9Xq1003": ["downloadURL": ""],
            "-Nf3k9Xq1004": "imagename",
        ]

        #expect(ArchiveParser.fileURLs(in: uploads).map(\.absoluteString) == [Raw.page(1)])
    }

    @Test("Array-shaped nodes (keys 0, 1, 2…) are read like objects, skipping empty slots")
    func arrayShapedNodes() throws {
        let raw: [String: Any] = [
            "imagename": "2019 FİNAL",
            "JPG": [NSNull(), Raw.file(Raw.page(1)), NSNull(), Raw.file(Raw.page(2))] as [Any],
        ]

        #expect(ArchiveParser.examSummary(in: raw) == ExamSummary(kind: .images, fileCount: 2))
        let document = try #require(ArchiveParser.document(in: raw, at: Fixture.imagesExam))
        #expect(document.fileURLs.map(\.absoluteString) == Raw.pages(2))
    }

    @Test("Array-shaped nodes keep their order past ten entries")
    func arrayShapedNodesPastTenEntries() {
        let pages = Raw.pages(12)
        let raw = pages.map(Raw.file) as [Any]

        #expect(ArchiveParser.fileURLs(in: raw).map(\.absoluteString) == pages)
    }

    // MARK: - Sorting

    @Test("Entries follow Turkish alphabetical order", arguments: CollationCase.all)
    func collation(_ testCase: CollationCase) {
        let parent = ArchivePath(components: Array(Fixture.lesson.components.prefix(testCase.level.rawValue - 1)))
        let raw = Dictionary(uniqueKeysWithValues: testCase.expectedOrder.map { name in
            (name, Raw.node("name", name))
        })

        let names = ArchiveParser.items(in: raw, at: parent).map(\.name)

        #expect(names == testCase.expectedOrder)
    }
}

// MARK: - Cases

/// Raw values that are not archive nodes.
nonisolated enum RawValueCase: CaseIterable, Sendable, CustomTestStringConvertible {
    case missing
    case null
    case emptyObject
    case emptyArray
    case string
    case number

    var value: Any? {
        switch self {
        case .missing: nil
        case .null: NSNull()
        case .emptyObject: [String: Any]()
        case .emptyArray: [Any]()
        case .string: "uniname"
        case .number: 42
        }
    }

    var testDescription: String {
        switch self {
        case .missing: "nil"
        case .null: "NSNull"
        case .emptyObject: "{}"
        case .emptyArray: "[]"
        case .string: "string leaf"
        case .number: "number leaf"
        }
    }
}

/// Names of one level and the order they must be listed in.
nonisolated struct CollationCase: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let level: ArchiveLevel
    let expectedOrder: [String]

    static let all: [CollationCase] = [
        CollationCase(
            testDescription: "Ç comes after every C and before D",
            level: .university,
            expectedOrder: [
                "CELAL BAYAR ÜNİVERSİTESİ",
                "CUMHURİYET ÜNİVERSİTESİ",
                "ÇANAKKALE ONSEKİZ MART ÜNİVERSİTESİ",
                "ÇUKUROVA ÜNİVERSİTESİ",
                "DİCLE ÜNİVERSİTESİ",
            ]
        ),
        CollationCase(
            testDescription: "İ comes right after I, not after Z",
            level: .university,
            expectedOrder: ["Hacettepe", "Istanbul", "İzmir", "Jandarma", "Zonguldak"]
        ),
        CollationCase(
            testDescription: "Names starting with dotless I precede those starting with dotted İ",
            level: .university,
            expectedOrder: [
                "IĞDIR ÜNİVERSİTESİ",
                "ISPARTA UYGULAMALI BİLİMLER ÜNİVERSİTESİ",
                "İNÖNÜ ÜNİVERSİTESİ",
                "İSTANBUL ÜNİVERSİTESİ",
            ]
        ),
        CollationCase(
            testDescription: "Ö comes after every O and before P",
            level: .university,
            expectedOrder: [
                "ORDU ÜNİVERSİTESİ",
                "OSMANİYE KORKUT ATA ÜNİVERSİTESİ",
                "ÖMER HALİSDEMİR ÜNİVERSİTESİ",
                "PAMUKKALE ÜNİVERSİTESİ",
            ]
        ),
        CollationCase(
            testDescription: "Ş comes after every S and before T",
            level: .university,
            expectedOrder: [
                "SAKARYA ÜNİVERSİTESİ",
                "SİİRT ÜNİVERSİTESİ",
                "SÜLEYMAN DEMİREL ÜNİVERSİTESİ",
                "ŞIRNAK ÜNİVERSİTESİ",
                "TRAKYA ÜNİVERSİTESİ",
            ]
        ),
        CollationCase(
            testDescription: "Ü comes after every U and before V",
            level: .university,
            expectedOrder: [
                "ULUDAĞ ÜNİVERSİTESİ",
                "UŞAK ÜNİVERSİTESİ",
                "ÜSKÜDAR ÜNİVERSİTESİ",
                "VAN YÜZÜNCÜ YIL ÜNİVERSİTESİ",
            ]
        ),
        CollationCase(
            testDescription: "Letter case is ignored",
            level: .faculty,
            expectedOrder: ["Adana", "ankara", "BOZOK", "Cizre", "çorum"]
        ),
        CollationCase(
            testDescription: "Numbers compare by value",
            level: .lesson,
            expectedOrder: ["1. Sınıf", "2. Sınıf", "10. Sınıf"]
        ),
        CollationCase(
            testDescription: "Exams are listed newest first",
            level: .exam,
            expectedOrder: ["2019 FİNAL", "2018 VİZE", "2010 BÜTÜNLEME", "2009 FİNAL", "2002 VİZE"]
        ),
    ]
}

// MARK: - Raw database values

/// Builders for raw Realtime Database values, shaped like the production tree.
private enum Raw {
    /// An archive node: its children plus the string leaf that stores its own name.
    static func node(_ placeholderKey: String, _ name: String, children: [String: Any] = [:]) -> [String: Any] {
        var node = children
        node[placeholderKey] = name
        return node
    }

    /// An exam node with optional `JPG` / `PDF` uploads.
    static func exam(_ name: String, jpg: [String] = [], pdf: [String] = []) -> [String: Any] {
        var node: [String: Any] = ["imagename": name]
        if !jpg.isEmpty {
            node[ExamKind.images.rawValue] = uploads(jpg)
        }
        if !pdf.isEmpty {
            node[ExamKind.pdf.rawValue] = uploads(pdf)
        }
        return node
    }

    /// `<pushId>/downloadURL` entries whose push ids sort in the given order.
    static func uploads(_ urls: [String]) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: urls.enumerated().map { index, url in
            ("-Nf3k9Xq\(1000 + index)", file(url) as Any)
        })
    }

    static func file(_ url: String) -> [String: Any] {
        ["downloadURL": url]
    }

    static func page(_ number: Int) -> String {
        "https://firebasestorage.googleapis.com/v0/b/vifi.appspot.com/o/sayfa-\(number).jpg?alt=media"
    }

    static func pages(_ count: Int) -> [String] {
        (1...count).map(page)
    }

    static func pdfs(_ count: Int) -> [String] {
        (1...count).map { "https://firebasestorage.googleapis.com/v0/b/vifi.appspot.com/o/sinav-\($0).pdf?alt=media" }
    }

    static func urls(_ strings: [String]) throws -> [URL] {
        try strings.map { try #require(URL(string: $0)) }
    }
}

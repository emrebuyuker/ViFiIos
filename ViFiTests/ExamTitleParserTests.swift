import Testing
@testable import ViFi

/// Same cases as `firebase/tests/conversionSchema.test.mjs` ("exam title parser", "exam-name list", "canonical list
/// title", "list title validation"): the server and the app must split and convert titles identically, or practice
/// pools, exam types and the admin's title picker diverge.
@Suite("ExamTitleParser")
struct ExamTitleParserTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let title: String
        let examType: ExamType?
        let year: Int?

        var testDescription: String { "\"\(title)\"" }
    }

    nonisolated static let cases: [Case] = [
        Case(title: "2019 FİNAL", examType: .final, year: 2019),
        Case(title: "2018 VİZE", examType: .vize, year: 2018),
        Case(title: "2017-2018 VİZE", examType: .vize, year: 2018),
        Case(title: "2019 2020 FİNAL", examType: .final, year: 2020),
        Case(title: "2020 BÜTÜNLEME", examType: .butunleme, year: 2020),
        Case(title: "2021 MAZERET", examType: .mazeret, year: 2021),
        Case(title: "2019 KISA SINAV 2", examType: .kisaSinav, year: 2019),
        Case(title: "KISA SINAV 3", examType: .kisaSinav, year: nil),
        Case(title: "2019 ARASINAV", examType: .araSinav, year: 2019),
        Case(title: "2022 ARA SINAV", examType: .araSinav, year: 2022),
        Case(title: "2019 YAZ OKULU FİNAL", examType: .final, year: 2019),
        Case(title: "2019 VİZE YAZ OKULU", examType: .vize, year: 2019),
        Case(title: "2023 YAZ OKULU", examType: .yazOkulu, year: 2023),
        Case(title: "FİNAL", examType: .final, year: nil),
        Case(title: "DERS NOTU", examType: nil, year: nil),
        Case(title: "2019 TEK DERS", examType: .tekDers, year: 2019),
        Case(title: "2020 EK SINAV", examType: .ekSinav, year: 2020),
        Case(title: "2020 YEDEK SINAV", examType: nil, year: 2020),
        Case(title: "2021 YAZ OKULU VİZE", examType: .vize, year: 2021),
        Case(title: "2021 YAZ OKULU ARA SINAV", examType: .araSinav, year: 2021),
        Case(title: "2021 YAZ OKULU FİNAL", examType: .final, year: 2021),
        Case(title: "QUIZ", examType: .kisaSinav, year: nil),
        Case(title: "2018 QUIZ 2", examType: .kisaSinav, year: 2018),
        Case(title: "2022 MUAFİYET SINAVI", examType: .muafiyet, year: 2022),
        Case(title: "2022 SEVİYE TESPİT SINAVI", examType: .seviyeTespit, year: 2022),
        Case(title: "2022 UYGULAMA SINAVI", examType: .uygulama, year: 2022),
        Case(title: "2022 UYGULAMA", examType: nil, year: 2022),
        Case(title: "2018 LABORATUVAR", examType: .laboratuvar, year: 2018),
        Case(title: "2018 ÖDEV", examType: .odev, year: 2018),
        Case(title: "2018 PROJE", examType: .proje, year: 2018),
        Case(title: "2018 ÇALIŞMA SORULARI", examType: .calismaSorulari, year: 2018),
        Case(title: "2018 ÇÖZÜMLÜ SORULAR", examType: .cozumluSorular, year: 2018),
        Case(title: "FİNAL ÇALIŞMA SORULARI", examType: .calismaSorulari, year: nil),
        Case(title: "2019 VİZE ÇÖZÜMLÜ SORULAR", examType: .cozumluSorular, year: 2019),
        Case(title: "2019 VİZE CEVAPLI", examType: .vize, year: 2019),
        Case(title: "", examType: nil, year: nil),
    ]

    struct CanonicalCase: Sendable, CustomTestStringConvertible {
        let title: String
        let expected: String?
        let entryId: String?

        var testDescription: String { "\"\(title)\"" }
    }

    nonisolated static let canonicalCases: [CanonicalCase] = [
        .init(title: "2019 KISA SINAV 2", expected: "2019 KISA SINAV 2", entryId: "kisa-sinav-2"),
        .init(title: "2017-2018 VİZE", expected: "2018 VİZE", entryId: "vize"),
        .init(title: "2019 2020 FİNAL", expected: "2020 FİNAL", entryId: "final"),
        .init(title: "2019 FİZİK LAB", expected: "2019 LABORATUVAR", entryId: "laboratuvar"),
        .init(title: "2018 FİZİK LABORATUAR 2", expected: "2018 LABORATUVAR 2", entryId: "laboratuvar"),
        .init(title: "2019 VİZE YAZ OKULU", expected: "2019 YAZ OKULU VİZE", entryId: "yaz-okulu-vize"),
        .init(title: "2021 YAZ OKULU ARA SINAV", expected: "2021 YAZ OKULU ARA SINAV", entryId: "yaz-okulu-ara-sinav"),
        .init(title: "2021 YAZ OKULU FİNAL", expected: "2021 YAZ OKULU FİNAL", entryId: "yaz-okulu-final"),
        .init(title: "2019 YAZ OKULU BÜTÜNLEME", expected: "2019 BÜTÜNLEME", entryId: "butunleme"),
        .init(title: "QUIZ 3", expected: "KISA SINAV 3", entryId: "kisa-sinav-3"),
        .init(title: "QUIZ 2", expected: "KISA SINAV 2", entryId: "kisa-sinav-2"),
        .init(title: "QUIZ 5", expected: "KISA SINAV 5", entryId: "kisa-sinav"),
        .init(title: "2018 KISA SINAV 12", expected: "2018 KISA SINAV 12", entryId: "kisa-sinav"),
        .init(title: "QUIZ", expected: "KISA SINAV", entryId: "kisa-sinav"),
        .init(title: "2018 FİNAL ÇALIŞMA SORULARI", expected: "2018 ÇALIŞMA SORULARI", entryId: "calisma-sorulari"),
        .init(title: "2019 FİNAL", expected: "2019 FİNAL", entryId: "final"),
        .init(title: "FİNAL", expected: "FİNAL", entryId: "final"),
        .init(title: "MATEMATİK 2 FİNAL", expected: "FİNAL", entryId: "final"),
        .init(title: "2019 VİZE 2", expected: "2019 VİZE 2", entryId: "vize"),
        .init(title: "2019 VİZE CEVAPLI", expected: "2019 VİZE", entryId: "vize"),
        .init(title: "2019 ARASINAV", expected: "2019 ARA SINAV", entryId: "ara-sinav"),
        .init(title: "2020 EK SINAVI", expected: "2020 EK SINAV", entryId: "ek-sinav"),
        .init(title: "2018 ÖDEVLER", expected: "2018 ÖDEV", entryId: "odev"),
        .init(title: "2019 PROJESİ", expected: "2019 PROJE", entryId: "proje"),
        .init(title: "2022 MUAFİYET SINAVI", expected: "2022 MUAFİYET SINAVI", entryId: "muafiyet"),
        .init(title: "2023 YAZ OKULU", expected: nil, entryId: nil),
        .init(title: "DERS NOTU", expected: nil, entryId: nil),
        .init(title: "SİSTEM", expected: nil, entryId: nil),
        .init(title: "POSTER", expected: nil, entryId: nil),
        .init(title: "2019 TEK", expected: nil, entryId: nil),
        .init(title: "2022 UYGULAMA", expected: nil, entryId: nil),
        .init(title: "", expected: nil, entryId: nil),
    ]

    nonisolated static let acceptedListTitles: [(String, String)] = [
        ("2019 VİZE", "2019 VİZE"),
        ("VİZE", "VİZE"),
        ("KISA SINAV 2", "KISA SINAV 2"),
        ("KISA SINAV 5", "KISA SINAV 5"),
        ("2018 YAZ OKULU FİNAL", "2018 YAZ OKULU FİNAL"),
        ("ÇÖZÜMLÜ SORULAR 99", "ÇÖZÜMLÜ SORULAR 99"),
        ("  2019   FİNAL ", "2019 FİNAL"),
    ]

    nonisolated static let rejectedListTitles = [
        "2017-2018 VİZE", "2019 VIZE", "vize", "VİZE 0", "VİZE 100", "VİZE 05", "KISA SINAV 2 3", "DERS NOTU",
        "19 VİZE", "1899 VİZE", "2019 FİZİK VİZE", "VİZE 2019", "",
    ]

    @Test("Archive titles convert to list titles like the server (K28)", arguments: canonicalCases)
    func canonicalTitles(_ testCase: CanonicalCase) {
        let result = ExamTitleParser.canonicalTitle(testCase.title)
        #expect(result?.title == testCase.expected)
        #expect(result?.entryId == testCase.entryId)
        if let result {
            #expect(ExamListTitle.parse(result.title)?.title == result.title)
            #expect(ExamTitleParser.parse(result.title).examType == result.examType)
        }
    }

    @Test("List titles are validated like the server")
    func listTitleValidation() {
        for (title, normalized) in Self.acceptedListTitles {
            #expect(ExamListTitle.parse(title)?.title == normalized, "\(title)")
        }
        for title in Self.rejectedListTitles {
            #expect(ExamListTitle.parse(title) == nil, "\(title)")
        }
        #expect(ExamListTitle.parse("2018 KISA SINAV 1") == ExamListTitle(year: 2018, entryId: "kisa-sinav-1", number: nil))
        #expect(ExamListTitle.parse("KISA SINAV 7") == ExamListTitle(year: nil, entryId: "kisa-sinav", number: 7))
        #expect(ExamListTitle(year: 2019, entryId: "yaz-okulu-vize", number: 2).title == "2019 YAZ OKULU VİZE 2")
    }

    @Test("Titles split into type and year like the server", arguments: cases)
    func parses(_ testCase: Case) {
        #expect(ExamTitleParser.parse(testCase.title) == .init(examType: testCase.examType, year: testCase.year))
    }

    @Test("Every Add Exam list name parses to its entry's exam type and is its own list title")
    func catalogNamesParseToTheirTypes() {
        for entry in ExamNameCatalog.entries {
            #expect(ExamTitleParser.parse("2024 \(entry.name)") == .init(examType: entry.examType, year: 2024), "\(entry.name)")
            #expect(ExamTitleParser.canonicalTitle("2024 \(entry.name)") == .init(
                title: "2024 \(entry.name)", entryId: entry.id, examType: entry.examType
            ), "\(entry.name)")
            #expect(ExamListTitle.parse(entry.name)?.title == entry.name)
        }
    }

    @Test("Add Exam list ids are unique and the picker shows the entries")
    func catalogIdsAreUnique() {
        let ids = ExamNameCatalog.entries.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ExamNameCatalog.names.map(\.id) == ids)
    }

    @Test("Add Exam list ids, names and order are the owner's and the server's (K27, K29)")
    func catalogOrder() {
        #expect(ExamNameCatalog.entries.map { [$0.id, $0.name] } == [
            ["vize", "VİZE"], ["ara-sinav", "ARA SINAV"], ["final", "FİNAL"], ["butunleme", "BÜTÜNLEME"],
            ["mazeret", "MAZERET"], ["tek-ders", "TEK DERS"], ["ek-sinav", "EK SINAV"],
            ["yaz-okulu-vize", "YAZ OKULU VİZE"], ["yaz-okulu-ara-sinav", "YAZ OKULU ARA SINAV"],
            ["yaz-okulu-final", "YAZ OKULU FİNAL"], ["kisa-sinav", "KISA SINAV"], ["kisa-sinav-1", "KISA SINAV 1"],
            ["kisa-sinav-2", "KISA SINAV 2"], ["kisa-sinav-3", "KISA SINAV 3"], ["muafiyet", "MUAFİYET SINAVI"],
            ["seviye-tespit", "SEVİYE TESPİT SINAVI"], ["uygulama", "UYGULAMA SINAVI"], ["laboratuvar", "LABORATUVAR"],
            ["odev", "ÖDEV"], ["proje", "PROJE"], ["calisma-sorulari", "ÇALIŞMA SORULARI"],
            ["cozumlu-sorular", "ÇÖZÜMLÜ SORULAR"],
        ])
    }

    @Test("Study materials are not practice exam types (K27)")
    func practiceEligibility() {
        let excluded = ExamType.allCases.filter { !$0.isPracticeEligible }
        #expect(excluded == [.laboratuvar, .odev, .proje, .calismaSorulari, .cozumluSorular])
        #expect(ExamType.allCases.map(\.rawValue) == [
            "vize", "final", "butunleme", "mazeret", "kisa-sinav", "yaz-okulu", "ara-sinav",
            "tek-ders", "ek-sinav", "muafiyet", "seviye-tespit", "uygulama",
            "laboratuvar", "odev", "proje", "calisma-sorulari", "cozumlu-sorular",
        ])
    }
}

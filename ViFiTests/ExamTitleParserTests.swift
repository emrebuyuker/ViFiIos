import Testing
@testable import ViFi

/// Same cases as `firebase/tests/conversionSchema.test.mjs` ("exam title parser"): the server and the app must split
/// titles identically, or practice pools and exam types diverge.
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
        Case(title: "2017-2018 VİZE", examType: .vize, year: 2017),
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

    @Test("Titles split into type and year like the server", arguments: cases)
    func parses(_ testCase: Case) {
        #expect(ExamTitleParser.parse(testCase.title) == .init(examType: testCase.examType, year: testCase.year))
    }

    @Test("Every Add Exam list name parses to its entry's exam type") @MainActor
    func catalogNamesParseToTheirTypes() {
        for entry in ExamNameCatalog.entries {
            #expect(ExamTitleParser.parse("2024 \(entry.name)") == .init(examType: entry.examType, year: 2024), "\(entry.name)")
        }
    }

    @Test("Add Exam list ids are unique and the picker shows the entries") @MainActor
    func catalogIdsAreUnique() {
        let ids = ExamNameCatalog.entries.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ExamNameCatalog.names.map(\.id) == ids)
    }

    @Test("Add Exam list order is the owner's (K27)") @MainActor
    func catalogOrder() {
        #expect(ExamNameCatalog.entries.map(\.name) == [
            "VİZE", "ARA SINAV", "FİNAL", "BÜTÜNLEME", "MAZERET", "TEK DERS", "EK SINAV",
            "YAZ OKULU VİZE", "YAZ OKULU ARA SINAV", "YAZ OKULU FİNAL", "KISA SINAV", "MUAFİYET SINAVI",
            "SEVİYE TESPİT SINAVI", "UYGULAMA SINAVI", "LABORATUVAR", "ÖDEV", "PROJE", "ÇALIŞMA SORULARI",
            "ÇÖZÜMLÜ SORULAR",
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

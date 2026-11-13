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
        Case(title: "2019 TEK DERS", examType: nil, year: 2019),
        Case(title: "", examType: nil, year: nil),
    ]

    @Test("Titles split into type and year like the server", arguments: cases)
    func parses(_ testCase: Case) {
        #expect(ExamTitleParser.parse(testCase.title) == .init(examType: testCase.examType, year: testCase.year))
    }

    @Test("Every Add Exam catalog name has an exam type with the same id") @MainActor
    func catalogIdsMatchExamTypes() {
        #expect(ExamNameCatalog.names.map(\.id) == ExamType.allCases.map(\.rawValue))
        for item in ExamNameCatalog.names {
            #expect(ExamTitleParser.parse("2024 \(item.name)").examType?.rawValue == item.id)
        }
    }
}

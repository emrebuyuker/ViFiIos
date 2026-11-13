import Foundation

/// Splits an archive exam title ("2019 FİNAL", "2017-2018 VİZE", "KISA SINAV 3") into a canonical type and year.
///
/// A Swift port of `parseExamTitle` in `firebase/functions/conversions/schema.js`; both run the same cases
/// (`ExamTitleParserTests`, `conversionSchema.test.mjs`). The year is the first 19xx/20xx number (an academic-year
/// range keeps its first year). Types are matched on the title's slug in priority order: study materials first
/// ("FİNAL ÇALIŞMA SORULARI" is study material), then the specific exam kinds, then vize/final, so "2019 YAZ OKULU
/// FİNAL" is a final and "YAZ OKULU" alone is a summer-school exam. Needles match whole slug words only.
nonisolated enum ExamTitleParser {
    struct Result: Equatable, Sendable {
        let examType: ExamType?
        let year: Int?
    }

    /// Checked in order; the first hit wins.
    private static let typeKeys: [(ExamType, [String])] = [
        (.calismaSorulari, ["calisma-sorulari"]),
        (.cozumluSorular, ["cozumlu-sorular"]),
        (.laboratuvar, ["laboratuvar", "laboratuar", "lab"]),
        (.odev, ["odev", "odevi", "odevler"]),
        (.proje, ["proje", "projesi"]),
        (.butunleme, ["butunleme"]),
        (.mazeret, ["mazeret"]),
        (.tekDers, ["tek-ders"]),
        (.ekSinav, ["ek-sinav", "ek-sinavi"]),
        (.muafiyet, ["muafiyet"]),
        (.seviyeTespit, ["seviye-tespit"]),
        (.uygulama, ["uygulama-sinavi", "uygulama-sinav"]),
        (.kisaSinav, ["kisa-sinav", "kisa-sinavlari", "quiz"]),
        (.araSinav, ["ara-sinav", "arasinav"]),
        (.vize, ["vize"]),
        (.final, ["final"]),
        (.yazOkulu, ["yaz-okulu"]),
    ]

    static func parse(_ title: String) -> Result {
        let key = Slug.make(title)
        let year = key.split(separator: "-").lazy
            .compactMap { token -> Int? in
                guard token.count == 4, token.hasPrefix("19") || token.hasPrefix("20") else { return nil }
                return Int(token)
            }
            .first
        let padded = "-\(key)-"
        let type = typeKeys.first { _, needles in needles.contains { padded.contains("-\($0)-") } }?.0
        return Result(examType: type, year: year)
    }
}

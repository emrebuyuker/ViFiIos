import Foundation

/// Splits an archive exam title ("2019 FİNAL", "2017-2018 VİZE", "KISA SINAV 3") into a canonical type and year, and
/// turns it into a title from the exam-name list (owner decision K28).
///
/// A Swift port of `parseExamTitle` / `canonicalExamTitle` in `firebase/functions/conversions/schema.js`; both run the
/// same cases (`ExamTitleParserTests`, `conversionSchema.test.mjs`). The year is the first 19xx/20xx number; an
/// academic-year range gives its second year (K29). Types are matched on the title's slug in priority order: study
/// materials first ("FİNAL ÇALIŞMA SORULARI" is study material), then the specific exam kinds, then vize/final, so
/// "2019 YAZ OKULU FİNAL" is a final and "YAZ OKULU" alone is a summer-school exam. Needles match whole slug words only.
nonisolated enum ExamTitleParser {
    struct Result: Equatable, Sendable {
        let examType: ExamType?
        let year: Int?
    }

    /// The list title an archive title converts to (K28).
    struct CanonicalTitle: Equatable, Sendable {
        let title: String
        let entryId: String
        let examType: ExamType
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
        let tokens = key.split(separator: "-").map(String.init)
        let padded = "-\(key)-"
        let type = typeKeys.first { _, needles in needles.contains { padded.contains("-\($0)-") } }?.0
        return Result(examType: type, year: year(in: tokens).flatMap(Int.init))
    }

    /// The list title for `title` (K28), or `nil` when no list name matches. Title = year + list name + sequence
    /// number: the year as in `parse`; the name is the base type by `parse`'s priority without plain "yaz okulu" (a
    /// title that also says "yaz okulu" maps vize / ara sınav / final to the YAZ OKULU entries); the sequence number is
    /// a 1–99 number right after the matched type words, and a kısa sınav numbered 1–3 takes the list's own "KISA SINAV
    /// 1/2/3" name instead (K29). Every other word is dropped.
    static func canonicalTitle(_ title: String) -> CanonicalTitle? {
        let tokens = Slug.make(title).split(separator: "-").map(String.init)
        var match: (type: ExamType, end: Int)?
        search: for (type, needles) in typeKeys where type != .yazOkulu {
            for needle in needles {
                let words = needle.split(separator: "-").map(String.init)
                if let index = firstIndex(of: words, in: tokens) {
                    match = (type, index + words.count)
                    break search
                }
            }
        }
        guard let match else { return nil }
        let isSummer = firstIndex(of: ["yaz", "okulu"], in: tokens) != nil
        let summerEntry = isSummer ? ExamNameCatalog.entry(id: "yaz-okulu-\(match.type.rawValue)") : nil
        guard var entry = summerEntry ?? baseEntry(for: match.type) else { return nil }

        var number: Int?
        if match.end < tokens.count, tokens[match.end].count <= 2, let value = Int(tokens[match.end]), value >= 1 {
            number = value
        }
        if entry.id == "kisa-sinav", let value = number, let numbered = ExamNameCatalog.entry(id: "kisa-sinav-\(value)") {
            entry = numbered
            number = nil
        }
        let parts = [year(in: tokens), entry.name, number.map(String.init)].compactMap(\.self)
        return CanonicalTitle(title: parts.joined(separator: " "), entryId: entry.id, examType: entry.examType)
    }

    /// The first 19xx/20xx word, or the second year of an academic-year range ("2017-2018" → "2018", K29).
    private static func year(in tokens: [String]) -> String? {
        guard let index = tokens.firstIndex(where: isYear) else { return nil }
        if index + 1 < tokens.count, isYear(tokens[index + 1]) { return tokens[index + 1] }
        return tokens[index]
    }

    private static func isYear(_ token: String) -> Bool {
        token.count == 4 && (token.hasPrefix("19") || token.hasPrefix("20")) && token.allSatisfy(\.isASCIIDigit)
    }

    private static func baseEntry(for type: ExamType) -> ExamNameCatalog.Entry? {
        ExamNameCatalog.entries.first { entry in
            entry.examType == type && !entry.id.hasPrefix("yaz-okulu-") && !entry.id.hasPrefix("kisa-sinav-")
        }
    }

    private static func firstIndex(of words: [String], in tokens: [String]) -> Int? {
        guard !words.isEmpty, words.count <= tokens.count else { return nil }
        return (0...(tokens.count - words.count)).first { Array(tokens[$0..<($0 + words.count)]) == words }
    }
}

/// A title from the exam-name list (K28): `[<year> ]<list name>[ <1–99>]` with one 19xx/20xx year (K29). The admin's
/// title editor builds one from its parts; `parse` is the mirror of `parseListTitle` / `validateExamTitle` in
/// `firebase/functions/conversions/schema.js` (the name must be written exactly as in the list; "KISA SINAV 2" is the
/// list name itself and a numbered list name takes no extra number).
nonisolated struct ExamListTitle: Equatable, Sendable {
    let year: Int?
    let entryId: String
    let number: Int?

    /// The normalised title, as the server stores it.
    var title: String {
        let name = ExamNameCatalog.entry(id: entryId)?.name ?? ""
        return [year.map(String.init), name, number.map(String.init)].compactMap(\.self).joined(separator: " ")
    }

    static func parse(_ title: String) -> ExamListTitle? {
        var words = title.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace).map(String.init)
        let year = words.first.flatMap(Self.year)
        if year != nil { words.removeFirst() }
        // The longest list name wins ("KISA SINAV 2" over "KISA SINAV" + 2, "YAZ OKULU VİZE" over "VİZE").
        let candidates = ExamNameCatalog.entries.sorted { $0.name.count > $1.name.count }
        for entry in candidates {
            let nameWords = entry.name.split(separator: " ").map(String.init)
            guard words.starts(with: nameWords) else { continue }
            let rest = Array(words.dropFirst(nameWords.count))
            if rest.isEmpty { return ExamListTitle(year: year, entryId: entry.id, number: nil) }
            guard rest.count == 1, let number = sequenceNumber(rest[0]), !entry.id.hasPrefix("kisa-sinav-") else { continue }
            return ExamListTitle(year: year, entryId: entry.id, number: number)
        }
        return nil
    }

    /// A 19xx/20xx year word.
    static func year(_ word: String) -> Int? {
        guard word.count == 4, word.hasPrefix("19") || word.hasPrefix("20"), word.allSatisfy(\.isASCIIDigit) else { return nil }
        return Int(word)
    }

    /// `1`…`99` without a leading zero.
    static func sequenceNumber(_ word: String) -> Int? {
        guard (1...2).contains(word.count), word.allSatisfy(\.isASCIIDigit), !word.hasPrefix("0") else { return nil }
        return Int(word)
    }
}

private extension Character {
    nonisolated var isASCIIDigit: Bool { isASCII && isNumber }
}

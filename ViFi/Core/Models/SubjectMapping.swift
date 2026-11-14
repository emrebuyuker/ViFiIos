import Foundation

// Models of the admin subject-mapping screen (4.2.0 practice mode, owner decision P5): the country-wide course
// identities (`subjects/<id>`) and the courses mapped to each. Server contract: `listSubjects` in
// `firebase/functions/conversions/subjectsAdmin.js`.

/// One course catalog node that belongs to a subject, with the names that place it in the archive.
nonisolated struct SubjectCourse: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let universityId: String
    let universityName: String
    let facultyName: String
    let departmentName: String
    let questionCount: Int

    /// "Fakülte · Bölüm", skipping whichever part is empty.
    var place: String {
        [facultyName, departmentName].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// A country-wide course identity and the courses currently mapped to it.
nonisolated struct AdminSubject: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let aliases: [String]
    let courses: [SubjectCourse]

    var courseCount: Int { courses.count }
    var questionCount: Int { courses.reduce(0) { $0 + $1.questionCount } }
    var universityIds: Set<String> { Set(courses.map(\.universityId)) }
}

/// Where a course goes in `setCourseSubject`: an existing subject, or a new one created from a name.
nonisolated enum SubjectTarget: Equatable, Sendable {
    case existing(id: String)
    case new(name: String)
}

/// Finds subjects that probably are the same course under two names ("Olası eşleşme").
nonisolated enum SubjectNameSimilarity {
    /// Names closer than this edit-distance ratio count as the same course.
    private static let minimumRatio = 0.85
    /// A shorter name that is the start of a longer one counts when it has at least this many letters.
    private static let minimumPrefixLength = 6
    /// Names shorter than this are only ever equal, never "close".
    private static let minimumFuzzyLength = 5
    private static let bucketLength = 3
    private static let romanNumerals = ["i": "1", "ii": "2", "iii": "3", "iv": "4", "v": "5"]

    /// A subject name reduced to its comparable parts: letters and digits only (Turkish letters folded), plus the
    /// trailing course number with roman numerals as digits ("Fizik II" becomes `fizik` + `2`).
    struct Key: Equatable {
        let base: String
        let number: String
    }

    /// Lowercase, without diacritics, and with every Turkish i ("ı", "İ", "I") as plain "i", so "CIZGE" finds "Çizge".
    static func fold(_ text: String) -> String {
        text.replacing("ı", with: "i").replacing("İ", with: "i").replacing("I", with: "i")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
    }

    static func key(for name: String) -> Key {
        let folded = fold(name)
        var tokens = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        var number = ""
        if let last = tokens.last, tokens.count > 1 {
            if let roman = romanNumerals[last] {
                number = roman
                tokens.removeLast()
            } else if last.allSatisfy(\.isNumber) {
                number = last
                tokens.removeLast()
            }
        }
        return Key(base: tokens.joined(), number: number)
    }

    /// Whether two names look like the same course: same number, and equal bases, one the start of the other, or a
    /// small edit distance apart.
    static func areClose(_ lhs: String, _ rhs: String) -> Bool {
        areClose(key(for: lhs), key(for: rhs))
    }

    static func areClose(_ lhs: Key, _ rhs: Key) -> Bool {
        guard !lhs.base.isEmpty, !rhs.base.isEmpty, lhs.number == rhs.number else { return false }
        if lhs.base == rhs.base { return true }
        let (short, long) = lhs.base.count <= rhs.base.count ? (lhs.base, rhs.base) : (rhs.base, lhs.base)
        if short.count >= minimumPrefixLength, long.hasPrefix(short) { return true }
        guard short.count >= minimumFuzzyLength else { return false }
        let distance = editDistance(Array(lhs.base), Array(rhs.base))
        return 1 - Double(distance) / Double(long.count) >= minimumRatio
    }

    /// For every subject that has courses from only one university: the id of the closest-named other subject (the
    /// one with most courses wins a tie). Names are compared inside buckets of the same first letters, so a long
    /// list stays cheap.
    static func possibleMatches(in subjects: [AdminSubject]) -> [String: String] {
        let keys = Dictionary(subjects.map { ($0.id, key(for: $0.name)) }, uniquingKeysWith: { first, _ in first })
        var buckets: [String: [AdminSubject]] = [:]
        for subject in subjects {
            buckets[String(keys[subject.id]?.base.prefix(bucketLength) ?? ""), default: []].append(subject)
        }
        var matches: [String: String] = [:]
        for subject in subjects where subject.universityIds.count == 1 {
            guard let ownKey = keys[subject.id] else { continue }
            let bucket = buckets[String(ownKey.base.prefix(bucketLength))] ?? []
            let candidates = bucket.filter { $0.id != subject.id && areClose(ownKey, keys[$0.id] ?? ownKey) }
            if let best = candidates.min(by: { ($1.courseCount, $0.id) < ($0.courseCount, $1.id) }) {
                matches[subject.id] = best.id
            }
        }
        return matches
    }

    private static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        guard !lhs.isEmpty else { return rhs.count }
        guard !rhs.isEmpty else { return lhs.count }
        var previous = Array(0...rhs.count)
        for (row, left) in lhs.enumerated() {
            var current = [row + 1]
            for (column, right) in rhs.enumerated() {
                current.append(min(previous[column + 1] + 1, current[column] + 1, previous[column] + (left == right ? 0 : 1)))
            }
            previous = current
        }
        return previous[rhs.count]
    }
}

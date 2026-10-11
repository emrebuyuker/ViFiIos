import Foundation

/// Turns a display name into a stable, topic-safe slug (`[a-z0-9-]`), used as the canonical id for a
/// university / faculty / department when the user types one that is not on the bundled list.
///
/// Must stay in lockstep with the slug used to generate the bundled catalogs' ids, so a free-typed name that
/// matches a listed one yields the same id, and the ids are safe to use directly in FCM topic names.
nonisolated enum Slug {
    /// Turkish letters mapped to their ASCII base before lowercasing (plain lowercasing mishandles İ/I).
    private static let turkishMap: [Character: Character] = [
        "İ": "i", "I": "i", "ı": "i",
        "Ğ": "g", "ğ": "g",
        "Ü": "u", "ü": "u",
        "Ş": "s", "ş": "s",
        "Ö": "o", "ö": "o",
        "Ç": "c", "ç": "c",
    ]

    static func make(_ input: String) -> String {
        let lowered = String(input.map { turkishMap[$0] ?? $0 }).lowercased()

        // Keep ASCII letters/digits; collapse every other run into a single dash, with no leading or trailing
        // dash (the dash is only flushed right before the next kept character).
        var slug = ""
        var pendingDash = false
        for character in lowered {
            if character.isASCII, character.isLetter || character.isNumber {
                if pendingDash {
                    slug.append("-")
                    pendingDash = false
                }
                slug.append(character)
            } else if !slug.isEmpty {
                pendingDash = true
            }
        }
        return slug.isEmpty ? "unknown" : slug
    }
}

import Foundation

/// The display name of a catalog node created from a submission (4.2.0): whitespace collapsed and Turkish upper case
/// ("Güç elektroniği devreleri" → "GÜÇ ELEKTRONİĞİ DEVRELERİ"), like the rest of the archive. Ids (slugs) are
/// unaffected. Mirrors `catalogDisplayName` in `firebase/functions/conversions/schema.js` (same cases). Idempotent.
nonisolated enum CatalogName {
    private static let turkish = Locale(identifier: "tr_TR")

    static func display(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ").uppercased(with: turkish)
    }
}

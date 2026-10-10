import Foundation

/// Compares dotted numeric version strings ("2.0.10" > "2.0.9").
///
/// Missing trailing components count as zero, so "3.0" equals "3.0.0". A component with non-numeric
/// characters keeps its leading digits ("1-beta" → 1), or counts as zero when it has none.
nonisolated enum AppVersion {
    /// Whether `candidate` is a strictly later version than `other`.
    static func isVersion(_ candidate: String, newerThan other: String) -> Bool {
        let candidateComponents = numericComponents(of: candidate)
        let otherComponents = numericComponents(of: other)
        for index in 0..<max(candidateComponents.count, otherComponents.count) {
            let lhs = index < candidateComponents.count ? candidateComponents[index] : 0
            let rhs = index < otherComponents.count ? otherComponents[index] : 0
            if lhs != rhs {
                return lhs > rhs
            }
        }
        return false
    }

    /// "3.0.1" → [3, 0, 1]; a non-numeric component keeps its leading digits or counts as zero.
    static func numericComponents(of version: String) -> [Int] {
        version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { Int($0.prefix { $0.isASCII && $0.isNumber }) ?? 0 }
    }
}

import Foundation
import Testing
@testable import ViFi

@Suite("AppVersion")
struct AppVersionTests {
    @Test("Versions compare component by component, as numbers", arguments: VersionCase.all)
    func versionComparison(_ testCase: VersionCase) {
        #expect(AppVersion.isVersion(testCase.candidate, newerThan: testCase.installed) == testCase.isNewer)
    }

    @Test("Components parse to numbers, dropping non-numeric suffixes and padding")
    func componentParsing() {
        #expect(AppVersion.numericComponents(of: "3.0.1") == [3, 0, 1])
        #expect(AppVersion.numericComponents(of: " 3.0 ") == [3, 0])
        #expect(AppVersion.numericComponents(of: "1-beta.2") == [1, 2])
        #expect(AppVersion.numericComponents(of: "") == [0])
    }
}

nonisolated struct VersionCase: Sendable, CustomTestStringConvertible {
    let candidate: String
    let installed: String
    let isNewer: Bool

    var testDescription: String {
        "\(candidate) \(isNewer ? ">" : "≤") \(installed)"
    }

    static let all: [VersionCase] = [
        VersionCase(candidate: "2.0.10", installed: "2.0.9", isNewer: true),
        VersionCase(candidate: "2.0.9", installed: "2.0.10", isNewer: false),
        VersionCase(candidate: "3.0.1", installed: "3.0.0", isNewer: true),
        VersionCase(candidate: "3.1", installed: "3.0.9", isNewer: true),
        VersionCase(candidate: "10.0", installed: "9.9.9", isNewer: true),
        VersionCase(candidate: "4", installed: "3.9", isNewer: true),
        VersionCase(candidate: "3.0.1", installed: "3.0", isNewer: true),
        VersionCase(candidate: "3.0.0", installed: "3.0.0", isNewer: false),
        VersionCase(candidate: "3.0", installed: "3.0.0", isNewer: false),
        VersionCase(candidate: "3.0.0", installed: "3.0", isNewer: false),
        VersionCase(candidate: "2.9.9", installed: "3.0.0", isNewer: false),
    ]
}

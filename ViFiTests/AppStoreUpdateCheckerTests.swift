import Foundation
import Testing
@testable import ViFi

@Suite("AppStoreUpdateChecker")
struct AppStoreUpdateCheckerTests {
    @Test("Versions compare component by component, as numbers", arguments: VersionCase.all)
    func versionComparison(_ testCase: VersionCase) {
        #expect(AppStoreUpdateChecker.isVersion(testCase.candidate, newerThan: testCase.installed) == testCase.isNewer)
    }

    @Test("The lookup URL names the bundle and, for a two-letter region, the storefront", arguments: StorefrontCase.all)
    func lookupURL(_ testCase: StorefrontCase) throws {
        let url = try #require(
            AppStoreUpdateChecker.lookupURL(bundleIdentifier: "com.BuyukerYazilim.ViFi2", countryCode: testCase.countryCode)
        )
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let queryItems = components.queryItems ?? []

        #expect(components.scheme == "https")
        #expect(components.host == "itunes.apple.com")
        #expect(components.path == "/lookup")
        #expect(queryItems.first { $0.name == "bundleId" }?.value == "com.BuyukerYazilim.ViFi2")
        #expect(queryItems.first { $0.name == "country" }?.value == testCase.expectedCountry)
    }
}

/// Checks against the iTunes Lookup API, answered by `StubURLProtocol`.
///
/// Every test gets its own installed app (a temporary bundle at version 3.0.0) whose unique
/// identifier keys its stubbed reply, so the tests can run in parallel.
@Suite("AppStoreUpdateChecker lookup")
final class AppStoreLookupTests {
    private static let storeURL = "https://apps.apple.com/tr/app/vifi/id1234567890"

    private let installedApp: TemporaryBundle

    init() throws {
        installedApp = try TemporaryBundle(version: "3.0.0")
    }

    @Test("A newer App Store version is reported as an update")
    func newerVersion() async throws {
        let checker = try makeChecker(replying: .response(statusCode: 200, body: lookupBody(version: "3.1.0")))
        let storeURL = try #require(URL(string: Self.storeURL))

        #expect(await checker.availableUpdate() == AppUpdate(version: "3.1.0", storeURL: storeURL))
    }

    @Test("The same or an older App Store version is not an update", arguments: ["3.0.0", "3.0", "2.9.9"])
    func sameOrOlderVersion(storeVersion: String) async throws {
        let checker = try makeChecker(replying: .response(statusCode: 200, body: lookupBody(version: storeVersion)))

        #expect(await checker.availableUpdate() == nil)
    }

    @Test("A newer release that this iOS version can't install is not offered")
    func releaseNeedsNewerOS() async throws {
        let checker = try makeChecker(replying: .response(
            statusCode: 200,
            body: lookupBody(version: "3.1.0", minimumOsVersion: "99.0")
        ))

        #expect(await checker.availableUpdate() == nil)
    }

    @Test("A newer release installable on this iOS version is offered")
    func releaseSupportsThisOS() async throws {
        let checker = try makeChecker(replying: .response(
            statusCode: 200,
            body: lookupBody(version: "3.1.0", minimumOsVersion: "17.0")
        ))

        #expect(await checker.availableUpdate()?.version == "3.1.0")
    }

    @Test("An app missing from the storefront has no update")
    func emptyResults() async throws {
        let checker = try makeChecker(replying: .response(statusCode: 200, body: lookupBody(version: nil)))

        #expect(await checker.availableUpdate() == nil)
    }

    @Test("An HTTP error status means no update", arguments: [404, 500, 503])
    func httpError(statusCode: Int) async throws {
        let checker = try makeChecker(replying: .response(statusCode: statusCode, body: lookupBody(version: "9.0.0")))

        #expect(await checker.availableUpdate() == nil)
    }

    @Test("A malformed response means no update")
    func malformedResponse() async throws {
        let checker = try makeChecker(replying: .response(statusCode: 200, body: Data("<html></html>".utf8)))

        #expect(await checker.availableUpdate() == nil)
    }

    @Test("A connection failure means no update")
    func connectionFailure() async throws {
        let checker = try makeChecker(replying: .failure(.notConnectedToInternet))

        #expect(await checker.availableUpdate() == nil)
    }

    // MARK: - Helpers

    /// A checker for the installed app whose lookup request receives `reply`.
    private func makeChecker(replying reply: StubURLProtocol.Reply) throws -> AppStoreUpdateChecker {
        let url = try #require(AppStoreUpdateChecker.lookupURL(bundleIdentifier: installedApp.identifier, countryCode: "TR"))
        return AppStoreUpdateChecker(
            session: StubURLProtocol.session(answering: url, with: reply),
            bundle: installedApp.bundle,
            countryCode: "TR"
        )
    }

    /// An iTunes Lookup API response; `nil` gives an empty result list.
    private func lookupBody(version: String?, minimumOsVersion: String? = nil) throws -> Data {
        let results: [[String: Any]] = version.map { version in
            var release: [String: Any] = [
                "bundleId": installedApp.identifier,
                "version": version,
                "trackViewUrl": Self.storeURL,
                "trackName": "ViFi",
            ]
            release["minimumOsVersion"] = minimumOsVersion
            return [release]
        } ?? []
        return try JSONSerialization.data(withJSONObject: ["resultCount": results.count, "results": results])
    }
}

// MARK: - Cases

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

nonisolated struct StorefrontCase: Sendable, CustomTestStringConvertible {
    let countryCode: String?
    let expectedCountry: String?

    var testDescription: String {
        "\(countryCode ?? "nil") → \(expectedCountry ?? "no country")"
    }

    static let all: [StorefrontCase] = [
        StorefrontCase(countryCode: "TR", expectedCountry: "tr"),
        StorefrontCase(countryCode: "de", expectedCountry: "de"),
        StorefrontCase(countryCode: nil, expectedCountry: nil),
        StorefrontCase(countryCode: "", expectedCountry: nil),
        StorefrontCase(countryCode: "TUR", expectedCountry: nil),
        StorefrontCase(countryCode: "419", expectedCountry: nil),
    ]
}

import Foundation
import os

/// Compares the installed version with the latest App Store release, using the iTunes Lookup API.
final class AppStoreUpdateChecker: AppUpdateChecking {
    private let session: URLSession
    private let bundle: Bundle
    private let countryCode: String?

    /// - Parameter countryCode: The storefront to look the app up in (e.g. `"TR"`); `nil` uses the US store.
    init(
        session: URLSession = .shared,
        bundle: Bundle = .main,
        countryCode: String? = Locale.current.region?.identifier
    ) {
        self.session = session
        self.bundle = bundle
        self.countryCode = countryCode
    }

    func availableUpdate() async -> AppUpdate? {
        guard let bundleIdentifier = bundle.bundleIdentifier,
              let installedVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let lookupURL = Self.lookupURL(bundleIdentifier: bundleIdentifier, countryCode: countryCode) else {
            Logger.app.error("Update check skipped: the bundle has no identifier or version")
            return nil
        }

        do {
            var request = URLRequest(url: lookupURL, timeoutInterval: 15)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await session.data(for: request)

            if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                Logger.app.error("Update check failed with HTTP \(response.statusCode, privacy: .public)")
                return nil
            }
            guard let release = try await Self.latestRelease(in: data) else {
                Logger.app.info("Update check: the app is not listed in this storefront")
                return nil
            }
            guard Self.isVersion(release.version, newerThan: installedVersion) else {
                return nil
            }
            // Don't prompt for a release this device can't install.
            if let minimumOsVersion = release.minimumOsVersion,
               Self.isVersion(minimumOsVersion, newerThan: Self.deviceOSVersion) {
                Logger.app.info("Update \(release.version, privacy: .public) needs iOS \(minimumOsVersion, privacy: .public)")
                return nil
            }
            return AppUpdate(version: release.version, storeURL: release.trackViewUrl)
        } catch {
            Logger.app.error("Update check failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Whether `candidate` is a later version than `installed`, comparing numeric components
    /// ("2.0.10" > "2.0.9"); missing components count as zero, so "3.0" equals "3.0.0".
    nonisolated static func isVersion(_ candidate: String, newerThan installed: String) -> Bool {
        let candidateComponents = numericComponents(of: candidate)
        let installedComponents = numericComponents(of: installed)
        for index in 0..<max(candidateComponents.count, installedComponents.count) {
            let lhs = index < candidateComponents.count ? candidateComponents[index] : 0
            let rhs = index < installedComponents.count ? installedComponents[index] : 0
            if lhs != rhs {
                return lhs > rhs
            }
        }
        return false
    }

    /// `https://itunes.apple.com/lookup?bundleId=<id>&country=<cc>`; the country is omitted unless it is
    /// a two-letter region code.
    nonisolated static func lookupURL(bundleIdentifier: String, countryCode: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "itunes.apple.com"
        components.path = "/lookup"
        var queryItems = [URLQueryItem(name: "bundleId", value: bundleIdentifier)]
        if let countryCode, countryCode.count == 2, countryCode.allSatisfy({ $0.isASCII && $0.isLetter }) {
            queryItems.append(URLQueryItem(name: "country", value: countryCode.lowercased()))
        }
        components.queryItems = queryItems
        return components.url
    }
}

// MARK: - Parsing

private extension AppStoreUpdateChecker {
    nonisolated struct LookupResponse: Decodable {
        let results: [Release]
    }

    nonisolated struct Release: Decodable, Sendable {
        let version: String
        let trackViewUrl: URL
        /// The lowest iOS version the release installs on, e.g. "17.0".
        let minimumOsVersion: String?
    }

    @concurrent
    nonisolated static func latestRelease(in data: Data) async throws -> Release? {
        try JSONDecoder().decode(LookupResponse.self, from: data).results.first
    }

    /// The running iOS version as "major.minor.patch".
    nonisolated static var deviceOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// "3.0.1" → [3, 0, 1]; a non-numeric component ("1-beta") keeps its leading digits or counts as zero.
    nonisolated static func numericComponents(of version: String) -> [Int] {
        version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { Int($0.prefix { $0.isASCII && $0.isNumber }) ?? 0 }
    }
}

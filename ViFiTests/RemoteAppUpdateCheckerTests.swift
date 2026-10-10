import Foundation
import Testing
@testable import ViFi

@Suite("RemoteAppUpdateChecker")
struct RemoteAppUpdateCheckerTests {
    private static let installedVersion = "3.0.0"
    private static let storeURLString = "https://apps.apple.com/app/id1"
    private static let fallbackURLString = "https://fallback.example/app"

    // MARK: - Pure decision

    @Test("A minimum newer than installed requires an update, carrying its message")
    func requiredUpdate() throws {
        let url = try #require(URL(string: Self.storeURLString))
        let status = Self.status(.init(minimumVersion: "3.1.0", latestVersion: "3.1.0", storeURL: url, message: "Güncelle"))
        #expect(status == .required(AppUpdate(version: "3.1.0", storeURL: url, message: "Güncelle")))
    }

    @Test("A latest newer than installed, with a lower minimum, is optional")
    func optionalUpdate() throws {
        let url = try #require(URL(string: Self.storeURLString))
        let status = Self.status(.init(minimumVersion: "3.0.0", latestVersion: "3.2.0", storeURL: url, message: nil))
        #expect(status == .optional(AppUpdate(version: "3.2.0", storeURL: url, message: nil)))
    }

    @Test("Up to date when neither threshold is newer than installed")
    func upToDate() throws {
        let url = try #require(URL(string: Self.storeURLString))
        #expect(Self.status(.init(minimumVersion: "2.0.0", latestVersion: "3.0.0", storeURL: url, message: nil)) == .upToDate)
    }

    @Test("The required gate wins over the optional prompt when both are newer")
    func requiredWinsOverOptional() throws {
        let url = try #require(URL(string: Self.storeURLString))
        let status = Self.status(.init(minimumVersion: "3.5.0", latestVersion: "3.9.0", storeURL: url, message: nil))
        #expect(status == .required(AppUpdate(version: "3.5.0", storeURL: url, message: nil)))
    }

    @Test("The fallback store URL is used when the policy omits it")
    func fallbackStoreURL() throws {
        let fallback = try #require(URL(string: Self.fallbackURLString))
        let status = RemoteAppUpdateChecker.status(
            for: AppUpdateConfig(minimumVersion: "4.0.0", latestVersion: nil, storeURL: nil, message: nil),
            installedVersion: Self.installedVersion,
            fallbackStoreURL: fallback
        )
        #expect(status == .required(AppUpdate(version: "4.0.0", storeURL: fallback, message: nil)))
    }

    @Test("No store URL anywhere means no prompt, even when a newer version exists")
    func noStoreURLNoPrompt() {
        let status = RemoteAppUpdateChecker.status(
            for: AppUpdateConfig(minimumVersion: "9.0.0", latestVersion: "9.0.0", storeURL: nil, message: nil),
            installedVersion: Self.installedVersion,
            fallbackStoreURL: nil
        )
        #expect(status == .upToDate)
    }

    // MARK: - Live stream & latch

    @Test("The stream emits the current status from the live policy")
    func streamEmitsStatus() async throws {
        let url = try #require(URL(string: Self.storeURLString))
        let required = AppUpdateConfig(minimumVersion: "3.5.0", latestVersion: nil, storeURL: url, message: nil)
        let statuses = await collect(makeChecker([required]).statusChanges())
        #expect(statuses == [.required(AppUpdate(version: "3.5.0", storeURL: url, message: nil))])
    }

    @Test("A required gate stays latched when the policy later becomes unreadable")
    func latchKeepsGateOnUnreadablePolicy() async throws {
        let url = try #require(URL(string: Self.storeURLString))
        let required = AppUpdateConfig(minimumVersion: "3.5.0", latestVersion: nil, storeURL: url, message: nil)
        let gate = AppUpdateStatus.required(AppUpdate(version: "3.5.0", storeURL: url, message: nil))
        let statuses = await collect(makeChecker([required, nil]).statusChanges())
        #expect(statuses == [gate, gate])
    }

    @Test("The gate lifts when a successful read lowers the minimum below installed")
    func gateLiftsOnSuccessfulRelaxedRead() async throws {
        let url = try #require(URL(string: Self.storeURLString))
        let required = AppUpdateConfig(minimumVersion: "3.5.0", latestVersion: nil, storeURL: url, message: nil)
        let relaxed = AppUpdateConfig(minimumVersion: "2.0.0", latestVersion: "2.0.0", storeURL: url, message: nil)
        let gate = AppUpdateStatus.required(AppUpdate(version: "3.5.0", storeURL: url, message: nil))
        let statuses = await collect(makeChecker([required, relaxed]).statusChanges())
        #expect(statuses == [gate, .upToDate])
    }

    @Test("An unreadable policy with no active gate stays up to date")
    func unreadablePolicyWithoutGateIsUpToDate() async {
        #expect(await collect(makeChecker([nil]).statusChanges()) == [.upToDate])
    }

    // MARK: - Helpers

    private static func status(_ config: AppUpdateConfig) -> AppUpdateStatus {
        RemoteAppUpdateChecker.status(for: config, installedVersion: installedVersion, fallbackStoreURL: nil)
    }

    private func makeChecker(_ configs: [AppUpdateConfig?]) -> RemoteAppUpdateChecker {
        RemoteAppUpdateChecker(
            config: FakeConfigReader(configs),
            installedVersion: Self.installedVersion,
            fallbackStoreURL: nil
        )
    }

    private func collect(_ stream: AsyncStream<AppUpdateStatus>) async -> [AppUpdateStatus] {
        var result: [AppUpdateStatus] = []
        for await status in stream {
            result.append(status)
        }
        return result
    }
}

/// An `AppConfigReading` that replays a fixed sequence of policy values, then ends.
private final class FakeConfigReader: AppConfigReading {
    private let configs: [AppUpdateConfig?]

    init(_ configs: [AppUpdateConfig?]) {
        self.configs = configs
    }

    func configChanges() -> AsyncStream<AppUpdateConfig?> {
        let configs = configs
        return AsyncStream { continuation in
            for config in configs {
                continuation.yield(config)
            }
            continuation.finish()
        }
    }
}

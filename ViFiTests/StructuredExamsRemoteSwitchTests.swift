import Foundation
import Testing
@testable import ViFi

/// Emits a scripted list of reads, then finishes.
final class StubStructuredExamsConfigReader: StructuredExamsConfigReading {
    private let reads: [StructuredExamsConfig?]

    init(reads: [StructuredExamsConfig?] = []) {
        self.reads = reads
    }

    func configChanges() -> AsyncStream<StructuredExamsConfig?> {
        AsyncStream { continuation in
            for read in reads {
                continuation.yield(read)
            }
            continuation.finish()
        }
    }
}

@Suite("StructuredExamsRemoteSwitch")
struct StructuredExamsRemoteSwitchTests {
    private static func makeDefaults() throws -> UserDefaults {
        let name = "ViFiTests.structuredExams.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("The node parses Bools and Console strings; anything else is the enabled default")
    func parsing() {
        #expect(StructuredExamsConfig.parse(["enabled": false]) == StructuredExamsConfig(enabled: false))
        #expect(StructuredExamsConfig.parse(["enabled": "FALSE"]) == StructuredExamsConfig(enabled: false))
        #expect(StructuredExamsConfig.parse(["enabled": 0]) == .default)
        #expect(StructuredExamsConfig.parse(nil) == .default)
        #expect(StructuredExamsConfig.parse("x") == .default)
        #expect(StructuredExamsConfig.default.enabled)
    }

    @Test("A fresh install is enabled")
    func freshInstall() throws {
        let remote = StructuredExamsRemoteSwitch(reader: StubStructuredExamsConfigReader(), defaults: try Self.makeDefaults())
        #expect(remote.isEnabled)
    }

    @Test("A remote change is stored but applies only from the next launch; failed reads keep the stored value")
    func nextLaunchSemantics() async throws {
        let defaults = try Self.makeDefaults()
        let first = StructuredExamsRemoteSwitch(
            reader: StubStructuredExamsConfigReader(reads: [StructuredExamsConfig(enabled: false), nil]),
            defaults: defaults
        )
        first.start()
        await first.waitUntilReaderFinishes()
        #expect(first.isEnabled)

        let second = StructuredExamsRemoteSwitch(reader: StubStructuredExamsConfigReader(), defaults: defaults)
        #expect(!second.isEnabled)
    }
}

import Foundation
import Testing
@testable import ViFi

@Suite("CaptureShieldRemoteSwitch")
struct CaptureShieldRemoteSwitchTests {
    /// An isolated defaults suite, wiped on creation.
    private static func makeDefaults() throws -> UserDefaults {
        let name = "ViFiTests.captureShield.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - Parsing

    @Test("A well-formed node is read as written")
    func parsesWellFormedNode() {
        let config = CaptureShieldConfig.parse(["enabled": false, "coverMode": "always"])
        #expect(config == CaptureShieldConfig(enabled: false, coverMode: .always))
    }

    @Test("A missing node or a non-object value is the default")
    func missingNodeIsDefault() {
        #expect(CaptureShieldConfig.parse(nil) == .default)
        #expect(CaptureShieldConfig.parse(NSNull()) == .default)
        #expect(CaptureShieldConfig.parse("nonsense") == .default)
        #expect(CaptureShieldConfig.parse([String: Any]()) == .default)
    }

    @Test("The default is enabled with the fallback cover mode")
    func defaultValues() {
        #expect(CaptureShieldConfig.default.enabled)
        #expect(CaptureShieldConfig.default.coverMode == .fallback)
    }

    @Test("A malformed field falls back on its own, leaving the other field intact")
    func malformedFieldFallsBackIndependently() {
        let badMode = CaptureShieldConfig.parse(["enabled": false, "coverMode": "sometimes"])
        #expect(badMode == CaptureShieldConfig(enabled: false, coverMode: .fallback))
        let badFlag = CaptureShieldConfig.parse(["enabled": 7, "coverMode": "always"])
        #expect(badFlag == CaptureShieldConfig(enabled: true, coverMode: .always))
        let wrongTypes = CaptureShieldConfig.parse(["enabled": [1], "coverMode": 3])
        #expect(wrongTypes == .default)
    }

    @Test("Console-typed strings are accepted for both fields, case-insensitively")
    func acceptsConsoleStrings() {
        #expect(CaptureShieldConfig.parse(["enabled": "FALSE", "coverMode": "Always"])
            == CaptureShieldConfig(enabled: false, coverMode: .always))
        #expect(CaptureShieldConfig.parse(["enabled": "true"]).enabled)
    }

    // MARK: - Persistence and launch semantics

    @Test("A fresh install applies the default")
    func freshInstallIsDefault() throws {
        let remote = CaptureShieldRemoteSwitch(reader: StubCaptureShieldConfigReader(), defaults: try Self.makeDefaults())
        #expect(remote.isEnabled)
        #expect(remote.coverMode == .fallback)
    }

    @Test("A read is stored and applied at the next launch, not the current one")
    func readAppliesOnNextLaunch() async throws {
        let defaults = try Self.makeDefaults()
        let off = CaptureShieldConfig(enabled: false, coverMode: .always)
        let first = CaptureShieldRemoteSwitch(reader: StubCaptureShieldConfigReader(reads: [off]), defaults: defaults)
        first.start()
        await first.waitUntilReaderFinishes()

        // This launch is unchanged ...
        #expect(first.isEnabled)
        #expect(first.coverMode == .fallback)
        // ... the next one picks the stored value up.
        let second = CaptureShieldRemoteSwitch(reader: StubCaptureShieldConfigReader(), defaults: defaults)
        #expect(!second.isEnabled)
        #expect(second.coverMode == .always)
    }

    @Test("An unreadable read keeps the stored value; a deleted node resets it to the default")
    func unreadableKeepsStoredDeletedResets() async throws {
        let defaults = try Self.makeDefaults()
        let off = CaptureShieldConfig(enabled: false, coverMode: .always)
        let seeding = CaptureShieldRemoteSwitch(reader: StubCaptureShieldConfigReader(reads: [off]), defaults: defaults)
        seeding.start()
        await seeding.waitUntilReaderFinishes()

        let failing = CaptureShieldRemoteSwitch(reader: StubCaptureShieldConfigReader(reads: [nil]), defaults: defaults)
        failing.start()
        await failing.waitUntilReaderFinishes()
        #expect(CaptureShieldRemoteSwitch.mirrored(in: defaults) == off)

        let deleted = CaptureShieldRemoteSwitch(reader: StubCaptureShieldConfigReader(reads: [.default]), defaults: defaults)
        deleted.start()
        await deleted.waitUntilReaderFinishes()
        #expect(CaptureShieldRemoteSwitch.mirrored(in: defaults) == .default)
    }

    @Test("Stored garbage reads back as the default")
    func storedGarbageIsDefault() throws {
        let defaults = try Self.makeDefaults()
        defaults.set("yes", forKey: "captureShield.remoteEnabled")
        defaults.set("loud", forKey: "captureShield.remoteCoverMode")
        #expect(CaptureShieldRemoteSwitch.mirrored(in: defaults) == .default)
    }

    @Test("The local override switches the shield off whatever the stored value says")
    func forcedOffOverridesRemote() throws {
        let defaults = try Self.makeDefaults()
        let forced = CaptureShieldRemoteSwitch(reader: StubCaptureShieldConfigReader(), defaults: defaults, forcedOff: true)
        #expect(!forced.isEnabled)
        #expect(forced.isForcedOff)
        #expect(forced.launchConfig.enabled)
    }

    @Test("The launch argument is recognised only when present")
    func launchArgument() {
        #expect(AppEnvironment.isCaptureShieldForcedOff(arguments: ["-ViFiCaptureShieldOff"]))
        #expect(!AppEnvironment.isCaptureShieldForcedOff(arguments: ["-ViFiMockData"]))
    }
}

import Foundation
import Testing
@testable import ViFi

@Suite("CaptureShieldSwitch")
struct CaptureShieldSwitchTests {
    private static func makeDefaults() throws -> UserDefaults {
        let name = "ViFiTests.captureShield.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func isAlwaysOnWithFallbackCover() throws {
        let shield = CaptureShieldSwitch(defaults: try Self.makeDefaults())
        #expect(shield.isEnabled)
        #expect(shield.coverMode == .fallback)
    }

    /// A value stored by the removed remote switch can no longer turn the shield off, and is cleared.
    @Test func ignoresAndClearsTheRetiredRemoteValue() throws {
        let defaults = try Self.makeDefaults()
        defaults.set(false, forKey: "captureShield.remoteEnabled")
        defaults.set("always", forKey: "captureShield.remoteCoverMode")
        let shield = CaptureShieldSwitch(defaults: defaults)
        #expect(shield.isEnabled)
        #expect(shield.coverMode == .fallback)
        for key in CaptureShieldSwitch.retiredKeys {
            #expect(defaults.object(forKey: key) == nil)
        }
    }
}

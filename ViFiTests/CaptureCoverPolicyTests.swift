import Testing
@testable import ViFi

struct CaptureCoverPolicyTests {
    @Test func noCaptureNeverCovers() {
        for mode in [CaptureCoverMode.fallback, .always] {
            for shield in [true, false] {
                #expect(!CaptureCoverPolicy.shouldCover(isCaptured: false, mode: mode, shieldIsActive: shield))
            }
        }
    }

    @Test func fallbackCoversOnlyWithoutAnActiveShield() {
        #expect(CaptureCoverPolicy.shouldCover(isCaptured: true, mode: .fallback, shieldIsActive: false))
        #expect(!CaptureCoverPolicy.shouldCover(isCaptured: true, mode: .fallback, shieldIsActive: true))
    }

    @Test func alwaysCoversEveryCapture() {
        #expect(CaptureCoverPolicy.shouldCover(isCaptured: true, mode: .always, shieldIsActive: true))
        #expect(CaptureCoverPolicy.shouldCover(isCaptured: true, mode: .always, shieldIsActive: false))
    }

    @Test func remoteCoverModeMapsOneToOne() {
        #expect(CaptureCoverMode(.fallback) == .fallback)
        #expect(CaptureCoverMode(.always) == .always)
    }
}

import Foundation
import Testing
import UIKit
@testable import ViFi

/// The crash guard's launch arithmetic, on an isolated `UserDefaults` suite per test. A "crash" is simulated by
/// dropping a guard whose window never closed and starting a new one on the same suite (the next launch).
@MainActor
@Suite("CaptureShieldCrashGuard")
struct CaptureShieldCrashGuardTests {
    private static let stamp = "4.2.0(11)|26.5"

    /// Collects settle callbacks instead of sleeping, so a test closes windows when it wants.
    private final class ManualScheduler {
        var pending: [@MainActor () -> Void] = []

        func schedule(_ action: @escaping @MainActor () -> Void) {
            pending.append(action)
        }

        func fireAll() {
            let actions = pending
            pending.removeAll()
            actions.forEach { $0() }
        }
    }

    /// Mutable application state read by the guard's `isInBackground` closure.
    private final class AppState {
        var isInBackground = true
    }

    private let suiteName = "captureShieldCrashGuardTests.\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let scheduler = ManualScheduler()

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func launch(stamp: String = Self.stamp, inBackground: Bool = false) -> CaptureShieldCrashGuard {
        CaptureShieldCrashGuard(
            defaults: defaults,
            stamp: stamp,
            isInBackground: { inBackground },
            scheduleSettle: scheduler.schedule
        )
    }

    /// A launch that swaps once and dies before the window closes.
    private func crashingLaunch(stamp: String = Self.stamp) -> CaptureShieldCrashGuard {
        let guardian = launch(stamp: stamp)
        guardian.run(kind: "UIImageView|true") {}
        scheduler.pending.removeAll()  // the process is gone: its settle callbacks never run
        return guardian
    }

    private var strikes: Int {
        CaptureShieldCrashGuard.strikes(in: defaults, for: Self.stamp)
    }

    private var inFlight: String? {
        defaults.string(forKey: CaptureShieldCrashGuard.inFlightKey)
    }

    @Test("A normal launch: the marker is set during the window and cleared when it settles")
    func normalLaunch() {
        let guardian = launch()
        #expect(!guardian.isTripped)

        let result = guardian.run(kind: "UIImageView|true") { 42 }

        #expect(result == 42)
        #expect(inFlight == Self.stamp)
        scheduler.fireAll()
        #expect(inFlight == nil)
        #expect(strikes == 0)
        #expect(!launch().isTripped)
    }

    @Test("One death inside the window is a strike, not a trip")
    func singleCrash() {
        _ = crashingLaunch()

        let next = launch()

        #expect(strikes == 1)
        #expect(!next.isTripped)
        #expect(!next.didTripThisLaunch)
        #expect(inFlight == nil)
    }

    @Test("Two consecutive deaths trip the guard and it stays tripped on later launches")
    func twoConsecutiveCrashes() {
        _ = crashingLaunch()
        _ = crashingLaunch()

        let tripped = launch()
        #expect(tripped.isTripped)
        #expect(tripped.didTripThisLaunch)

        let later = launch()
        #expect(later.isTripped)
        #expect(!later.didTripThisLaunch)
    }

    @Test("A launch whose window settles clears the strike, so deaths must be consecutive")
    func successfulLaunchClearsStrikes() {
        _ = crashingLaunch()
        let survivor = launch()
        #expect(strikes == 1)
        survivor.run(kind: "UIImageView|true") {}
        scheduler.fireAll()
        #expect(strikes == 0)

        _ = crashingLaunch()
        #expect(!launch().isTripped)
        #expect(strikes == 1)
    }

    @Test("A new build or iOS version resets strikes and a trip", arguments: ["4.2.0(12)|26.5", "4.2.0(11)|26.6"])
    func newStampResets(newStamp: String) {
        _ = crashingLaunch()
        _ = crashingLaunch()
        #expect(launch().isTripped)

        let updated = launch(stamp: newStamp)

        #expect(!updated.isTripped)
        #expect(defaults.string(forKey: CaptureShieldCrashGuard.trippedKey) == nil)
        #expect(CaptureShieldCrashGuard.strikes(in: defaults, for: newStamp) == 0)
    }

    @Test("Strikes of another stamp do not add up with this one's")
    func strikesAreStampScoped() {
        _ = crashingLaunch(stamp: "4.2.0(10)|26.5")
        _ = crashingLaunch()

        #expect(!launch().isTripped)
        #expect(strikes == 1)
    }

    @Test("Only the first swap of each kind opens a window; the marker stays until the last window closes")
    func windowsPerKind() {
        let guardian = launch()
        guardian.run(kind: "UIImageView|true") {}
        guardian.run(kind: "UIImageView|true") {}
        #expect(scheduler.pending.count == 1)

        guardian.run(kind: "PDFView|true") {}
        #expect(scheduler.pending.count == 2)

        scheduler.pending.removeFirst()()
        #expect(inFlight == Self.stamp)
        scheduler.pending.removeFirst()()
        #expect(inFlight == nil)
    }

    @Test("Entering the background closes open windows; late settle callbacks change nothing")
    func backgroundClosesWindows() {
        _ = crashingLaunch()
        let guardian = launch()
        guardian.run(kind: "UIImageView|true") {}

        guardian.applicationDidEnterBackground()

        #expect(inFlight == nil)
        #expect(strikes == 0)
        // A window opened after returning must not be closed by the stale callback of the previous one.
        guardian.run(kind: "PDFView|true") {}
        scheduler.pending.removeFirst()()
        #expect(inFlight == Self.stamp)
        scheduler.fireAll()
        #expect(inFlight == nil)
    }

    @Test("A system kill after backgrounding is not a strike")
    func backgroundKillIsNotACrash() {
        for _ in 0..<3 {
            let guardian = launch()
            guardian.run(kind: "UIImageView|true") {}
            guardian.applicationDidEnterBackground()
            scheduler.pending.removeAll()  // suspended, then killed by the system
        }

        #expect(!launch().isTripped)
        #expect(strikes == 0)
    }

    @Test("A swap made in the background is not guarded and leaves the kind for the first foreground swap")
    func backgroundSwapIsUnguarded() {
        let state = AppState()
        let guardian = CaptureShieldCrashGuard(
            defaults: defaults,
            stamp: Self.stamp,
            isInBackground: { state.isInBackground },
            scheduleSettle: scheduler.schedule
        )

        guardian.run(kind: "UIImageView|true") {}
        #expect(inFlight == nil)
        #expect(scheduler.pending.isEmpty)

        state.isInBackground = false
        guardian.run(kind: "UIImageView|true") {}
        #expect(inFlight == Self.stamp)
    }

    @Test("A tripped guard makes the shield unavailable and every swap a no-op")
    func trippedGuardDisablesTheShield() {
        _ = crashingLaunch()
        _ = crashingLaunch()
        let shield = CaptureShield(crashGuard: launch())
        let view = UIView()

        #expect(!shield.isAvailable)
        #expect(!shield.setProtected(true, on: view))
        #expect((view.layer.value(forKey: "disableUpdateMask") as? NSNumber)?.intValue == 0)
    }

    @Test("An untripped guard brackets the shield's first swap of a kind")
    func shieldSwapsThroughTheGuard() {
        let shield = CaptureShield(crashGuard: launch())

        #expect(shield.isAvailable)
        #expect(shield.setProtected(true, on: UIView()))
        #expect(inFlight == Self.stamp)
        scheduler.fireAll()
        #expect(inFlight == nil)
    }
}

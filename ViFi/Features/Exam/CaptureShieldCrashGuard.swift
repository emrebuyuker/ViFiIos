import Foundation
import UIKit

/// Bounds the worst case of `CaptureShield`'s private layer swap to two crashes per app build and iOS version.
///
/// Before the first swap of each kind (target view class + direction) in a process, an in-flight marker carrying the
/// stamp `"<version>(<build>)|<iOS>"` is written and flushed. The marker is removed when the swap's window closes:
/// - `settleTime` after the swap (the layout passes and the Core Animation commit the swap triggers run inside it), or
/// - when the app enters the background. Reaching `didEnterBackground` means the main run loop has turned at least
///   once after the swap, so the swap and the commit it triggered already ran without crashing; what follows (a
///   suspension, a jetsam kill, a force quit from the app switcher) is not the swap's fault and must not count.
///
/// A launch that finds the marker of its own stamp records a strike: the previous launch died inside a window. One
/// strike is not enough, because a debugger stop or a crash elsewhere inside the window looks identical. Two launches
/// in a row trip the guard: the shield then stays off for that stamp (fail open; pages remain visible) until the app
/// build or the iOS version changes. A window that closes normally clears the strikes, so they must be consecutive.
///
/// Swaps made while the app is already in the background are not guarded and do not consume their kind, so the
/// kind's first foreground swap is still bracketed; a system kill in the background therefore never counts.
///
/// Main actor only (default isolation): markers, counters and the settle callbacks never race. Closed windows are
/// invalidated by `generation`, so a settle callback that fires after a background transition cannot clear twice.
final class CaptureShieldCrashGuard {
    static let inFlightKey = "captureShield.inFlight"
    static let strikesKey = "captureShield.strikes"
    static let trippedKey = "captureShield.tripped"
    /// How long after a guarded swap a crash still counts as the swap's.
    static let settleTime = Duration.seconds(1)
    /// Consecutive launches that must die inside a guarded window before the shield stays off.
    static let strikesToTrip = 2

    /// Runs `action` once a guarded swap's window has elapsed. Injected so tests can close windows on demand.
    typealias SettleScheduler = @MainActor (@escaping @MainActor () -> Void) -> Void

    /// `true` when the shield must stay off for this stamp.
    let isTripped: Bool
    /// `true` only on the launch whose start recorded the tripping strike (the fault is logged once, then).
    let didTripThisLaunch: Bool
    let stamp: String

    private let defaults: UserDefaults
    private let scheduleSettle: SettleScheduler
    private let isInBackground: @MainActor () -> Bool
    private var guardedKinds: Set<String> = []
    private var openWindows = 0
    private var generation = 0

    init(
        defaults: UserDefaults,
        stamp: String,
        isInBackground: @escaping @MainActor () -> Bool = { false },
        scheduleSettle: @escaping SettleScheduler = CaptureShieldCrashGuard.sleepThenRun
    ) {
        self.defaults = defaults
        self.stamp = stamp
        self.isInBackground = isInBackground
        self.scheduleSettle = scheduleSettle

        var didTrip = false
        if defaults.string(forKey: Self.inFlightKey) == stamp {
            // The previous launch never closed a guarded window: one more strike for this stamp.
            let strikes = Self.strikes(in: defaults, for: stamp) + 1
            defaults.set("\(stamp)#\(strikes)", forKey: Self.strikesKey)
            if strikes >= Self.strikesToTrip, defaults.string(forKey: Self.trippedKey) != stamp {
                defaults.set(stamp, forKey: Self.trippedKey)
                didTrip = true
            }
        }
        defaults.removeObject(forKey: Self.inFlightKey)
        if let tripped = defaults.string(forKey: Self.trippedKey), tripped != stamp {
            // A new build or iOS version starts over.
            defaults.removeObject(forKey: Self.trippedKey)
        }
        isTripped = defaults.string(forKey: Self.trippedKey) == stamp
        didTripThisLaunch = didTrip
    }

    /// The guard used by `CaptureShield.shared`. On sample data (`-ViFiMockData`: UI tests and the unit-test host)
    /// it runs on a suite that is wiped at every launch: test processes are killed right after a swap all the time,
    /// and their strikes must never switch the shield off for the next run.
    static func live() -> CaptureShieldCrashGuard {
        let defaults: UserDefaults
        if AppEnvironment.usesMockData(), let volatile = UserDefaults(suiteName: volatileSuiteName) {
            volatile.removePersistentDomain(forName: volatileSuiteName)
            defaults = volatile
        } else {
            defaults = .standard
        }
        return CaptureShieldCrashGuard(
            defaults: defaults,
            stamp: currentStamp,
            isInBackground: { UIApplication.shared.applicationState == .background }
        )
    }

    private static let volatileSuiteName = "captureShield.sampleData"

    /// `"<version>(<build>)|<iOS>"`: the guard is scoped to it.
    static var currentStamp: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version)(\(build))|\(UIDevice.current.systemVersion)"
    }

    /// Strikes recorded for `stamp`; those of another build or iOS version do not count.
    static func strikes(in defaults: UserDefaults, for stamp: String) -> Int {
        guard let value = defaults.string(forKey: strikesKey), value.hasPrefix(stamp + "#") else { return 0 }
        return Int(value.dropFirst(stamp.count + 1)) ?? 0
    }

    /// The default scheduler: `action` runs on the main actor `settleTime` after the swap.
    static func sleepThenRun(_ action: @escaping @MainActor () -> Void) {
        Task {
            try? await Task.sleep(for: settleTime)
            action()
        }
    }

    /// Runs `body`, bracketing the first foreground call of each `kind` in this process with the in-flight marker.
    func run<Result>(kind: String, _ body: () -> Result) -> Result {
        guard !isInBackground(), guardedKinds.insert(kind).inserted else { return body() }
        openWindows += 1
        if openWindows == 1 {
            defaults.set(stamp, forKey: Self.inFlightKey)
            // The marker must be on disk before the swap: a crash inside `body` gives no second chance.
            defaults.synchronize()
        }
        let result = body()
        let windowGeneration = generation
        scheduleSettle { [weak self] in
            self?.closeWindow(of: windowGeneration)
        }
        return result
    }

    /// Closes every open window: the swaps survived at least one run-loop turn (see the type's documentation).
    func applicationDidEnterBackground() {
        guard openWindows > 0 else { return }
        generation += 1
        openWindows = 0
        settle()
    }

    private func closeWindow(of windowGeneration: Int) {
        guard windowGeneration == generation, openWindows > 0 else { return }
        openWindows -= 1
        if openWindows == 0 {
            settle()
        }
    }

    private func settle() {
        defaults.removeObject(forKey: Self.inFlightKey)
        defaults.removeObject(forKey: Self.strikesKey)  // came back: strikes must be consecutive
    }
}

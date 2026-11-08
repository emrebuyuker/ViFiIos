import Foundation
import OSLog

/// The remote kill switch for the screen-capture shield: `config/captureProtection/ios` =
/// `{enabled: Bool, coverMode: "fallback" | "always"}` in the Realtime Database (readable under `config`, written only
/// in the Console).
///
/// - `enabled`: `false` turns the shield off (pages are shown as plain content; fail open).
/// - `coverMode`: `fallback` covers a page on the device only while it is captured and the shield is unavailable;
///   `always` covers it during every recording or mirroring, even with a working shield.
///
/// A missing node, a missing field or a malformed value means the default (`enabled = true`, `fallback`).
nonisolated struct CaptureShieldConfig: Equatable, Sendable {
    /// When protected pages are also covered on the device itself.
    enum CoverMode: String, Sendable, CaseIterable {
        case fallback
        case always
    }

    var enabled: Bool
    var coverMode: CoverMode

    /// What applies when nothing was ever read, and for any field the node lacks or gets wrong.
    static let `default` = CaptureShieldConfig(enabled: true, coverMode: .fallback)

    /// Parses the node's value (`snapshot.value`); call it inside the database callback so only a `Sendable` value
    /// leaves. Never fails: every field that is not well-formed falls back to its default.
    static func parse(_ value: Any?) -> CaptureShieldConfig {
        let node = value as? [String: Any] ?? [:]
        return CaptureShieldConfig(
            enabled: parseFlag(node["enabled"]) ?? Self.default.enabled,
            coverMode: parseCoverMode(node["coverMode"]) ?? Self.default.coverMode
        )
    }

    /// A Bool, or the strings "true" / "false" (a Console edit can store either); anything else is `nil`.
    static func parseFlag(_ value: Any?) -> Bool? {
        switch value {
        case let flag as Bool: flag
        case let text as String where text.lowercased() == "true": true
        case let text as String where text.lowercased() == "false": false
        default: nil
        }
    }

    /// A case-insensitive cover mode name; anything else is `nil`.
    static func parseCoverMode(_ value: Any?) -> CoverMode? {
        guard let text = value as? String else { return nil }
        return CoverMode(rawValue: text.lowercased())
    }
}

/// A source of the remote shield configuration.
protocol CaptureShieldConfigReading: AnyObject {
    /// Emits the node's parsed value each time it is read (cache first, then the server, then on every change).
    /// A node that does not exist emits `.default`. A read that failed emits `nil`: the caller keeps what it has.
    func configChanges() -> AsyncStream<CaptureShieldConfig?>
}

/// Reads nothing (mock and test environments): the shield keeps its launch value.
final class NoopCaptureShieldConfigReader: CaptureShieldConfigReading {
    func configChanges() -> AsyncStream<CaptureShieldConfig?> {
        AsyncStream { $0.finish() }
    }
}

/// The shield's switch for this launch, and the mirror that carries the remote value to the next one.
///
/// The value used while the app runs is read from `UserDefaults` **once, at creation**: a remote change is stored and
/// takes effect at the next launch, so a page never changes protection mid-view. `isEnabled` and `coverMode` are the
/// single place a consumer reads (`CaptureShieldedView`).
final class CaptureShieldRemoteSwitch {
    private static let enabledKey = "captureShield.remoteEnabled"
    private static let coverModeKey = "captureShield.remoteCoverMode"

    /// The remote configuration this launch applies (the mirror of the last successful read, or the default).
    let launchConfig: CaptureShieldConfig
    /// `true` when this launch forced the shield off locally (Debug `-ViFiCaptureShieldOff`).
    let isForcedOff: Bool

    private let reader: any CaptureShieldConfigReading
    private let defaults: UserDefaults
    private var observation: Task<Void, Never>?

    /// - Parameters:
    ///   - reader: Where the remote node is read from.
    ///   - defaults: Where the last read is mirrored.
    ///   - forcedOff: Switches the shield off for this launch regardless of the remote value (Debug only).
    init(
        reader: any CaptureShieldConfigReading,
        defaults: UserDefaults = .standard,
        forcedOff: Bool = false
    ) {
        self.reader = reader
        self.defaults = defaults
        isForcedOff = forcedOff
        launchConfig = Self.mirrored(in: defaults)
    }

    /// Whether the shield is on for this launch.
    var isEnabled: Bool { !isForcedOff && launchConfig.enabled }

    /// When protected pages are also covered on the device itself, for this launch.
    var coverMode: CaptureShieldConfig.CoverMode { launchConfig.coverMode }

    /// Starts mirroring the remote node. Idempotent; call once the database is configured.
    func start() {
        guard observation == nil else { return }
        let changes = reader.configChanges()
        observation = Task { [weak self] in
            for await config in changes {
                guard let config else { continue }
                self?.mirror(config)
            }
        }
    }

    /// Returns once the reader's stream has ended (only a finite stream does; for tests).
    func waitUntilReaderFinishes() async {
        await observation?.value
    }

    /// Stores one successful read for the next launch. Does not change `isEnabled` / `coverMode`.
    func mirror(_ config: CaptureShieldConfig) {
        defaults.set(config.enabled, forKey: Self.enabledKey)
        defaults.set(config.coverMode.rawValue, forKey: Self.coverModeKey)
        let state = "enabled \(config.enabled), cover \(config.coverMode.rawValue)"
        Logger.app.notice("Capture shield remote config stored for next launch: \(state, privacy: .public)")
    }

    /// The stored mirror; a field never stored, or stored badly, is its default.
    static func mirrored(in defaults: UserDefaults) -> CaptureShieldConfig {
        CaptureShieldConfig(
            enabled: defaults.object(forKey: enabledKey) as? Bool ?? CaptureShieldConfig.default.enabled,
            coverMode: CaptureShieldConfig.parseCoverMode(defaults.string(forKey: coverModeKey))
                ?? CaptureShieldConfig.default.coverMode
        )
    }

    deinit {
        observation?.cancel()
    }
}

import Foundation
import OSLog

/// The remote kill switch for the 4.2.0 structured-exam screen: `config/structuredExams/ios = {enabled: Bool}` in the
/// Realtime Database (readable under `config`, written only in the Console).
///
/// `enabled: false` shows every exam with the original file viewer even when it has questions (`exams/<id>.files` are
/// kept on structured exams until Faz 4). A missing node, field or malformed value means enabled.
nonisolated struct StructuredExamsConfig: Equatable, Sendable {
    var enabled: Bool

    static let `default` = StructuredExamsConfig(enabled: true)

    /// Parses the node's value inside the database callback; never fails.
    static func parse(_ value: Any?) -> StructuredExamsConfig {
        let node = value as? [String: Any] ?? [:]
        return StructuredExamsConfig(enabled: CaptureShieldConfig.parseFlag(node["enabled"]) ?? Self.default.enabled)
    }
}

/// A source of the remote structured-exams configuration.
protocol StructuredExamsConfigReading: AnyObject {
    /// Emits the node's parsed value each time it is read; a missing node emits `.default`, a failed read `nil`.
    func configChanges() -> AsyncStream<StructuredExamsConfig?>
}

/// Reads nothing (mock and test environments): the switch keeps its launch value.
final class NoopStructuredExamsConfigReader: StructuredExamsConfigReading {
    func configChanges() -> AsyncStream<StructuredExamsConfig?> {
        AsyncStream { $0.finish() }
    }
}

/// The structured-exam screen's switch for this launch, and the mirror carrying the remote value to the next one.
///
/// Like `CaptureShieldRemoteSwitch`, the launch value is read from `UserDefaults` once, at creation: a remote change
/// applies from the next launch, so an open exam never swaps between the question list and the page viewer.
final class StructuredExamsRemoteSwitch {
    private static let enabledKey = "structuredExams.remoteEnabled"

    /// Whether exams with questions open the question screen during this launch.
    let isEnabled: Bool

    private let reader: any StructuredExamsConfigReading
    private let defaults: UserDefaults
    private var observation: Task<Void, Never>?

    init(reader: any StructuredExamsConfigReading, defaults: UserDefaults = .standard) {
        self.reader = reader
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? StructuredExamsConfig.default.enabled
    }

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

    /// Stores one successful read for the next launch. Does not change `isEnabled`.
    func mirror(_ config: StructuredExamsConfig) {
        defaults.set(config.enabled, forKey: Self.enabledKey)
        Logger.app.notice("Structured exams remote switch stored for next launch: enabled \(config.enabled, privacy: .public)")
    }

    deinit {
        observation?.cancel()
    }
}

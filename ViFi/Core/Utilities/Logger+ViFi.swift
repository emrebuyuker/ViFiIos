import OSLog

extension Logger {
    // `nonisolated` so they can be used from background work too (`@concurrent` helpers); `Logger` is `Sendable`.
    private nonisolated static let subsystem = Bundle.main.bundleIdentifier ?? "com.BuyukerYazilim.ViFi2"

    nonisolated static let archive = Logger(subsystem: subsystem, category: "Archive")
    nonisolated static let files = Logger(subsystem: subsystem, category: "Files")
    nonisolated static let app = Logger(subsystem: subsystem, category: "App")
}

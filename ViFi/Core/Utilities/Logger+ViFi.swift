import OSLog

extension Logger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.BuyukerYazilim.ViFi2"

    static let archive = Logger(subsystem: subsystem, category: "Archive")
    static let files = Logger(subsystem: subsystem, category: "Files")
    static let app = Logger(subsystem: subsystem, category: "App")
}

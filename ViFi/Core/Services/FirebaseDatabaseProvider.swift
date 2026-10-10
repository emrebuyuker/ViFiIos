@preconcurrency import FirebaseDatabase
import Foundation

/// The single configured Realtime Database instance for the whole app.
///
/// Firebase only accepts persistence settings before the first reference is created, so every component
/// that reads the database (the archive repository and the remote-config reader) goes through this one
/// lazily initialised static. Swift runs it exactly once per process, before any reference exists, which
/// keeps the settings from being applied twice (a hard crash) and the cache shared across readers.
enum ViFiDatabase {
    static let shared: Database = {
        let database = Database.database()
        database.isPersistenceEnabled = true
        // Synced data is never evicted; the headroom keeps recently browsed nodes around as well.
        database.persistenceCacheSizeBytes = 50 * 1024 * 1024
        database.callbackQueue = DispatchQueue(label: "com.BuyukerYazilim.ViFi.database", qos: .userInitiated)
        return database
    }()
}

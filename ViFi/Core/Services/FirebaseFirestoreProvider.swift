@preconcurrency import FirebaseFirestore
import Foundation

/// The single configured Cloud Firestore instance for the whole app.
///
/// Firestore only accepts its settings before the first access, so every component that reads or writes
/// Firestore goes through this one lazily initialised static. Swift runs it exactly once per process, which
/// keeps the settings from being applied twice and the offline cache shared across readers — the same pattern
/// as `ViFiDatabase` for the Realtime Database.
///
/// Uses the named `vifi` database (Native mode, eur3): the project's `(default)` database is a legacy
/// Datastore-mode database (US, incompatible), so the archive lives in a dedicated Native database instead.
///
/// Persistence (offline) is on with the default on-disk cache; App Check attaches a token automatically once
/// Firestore enforcement is enabled in the console. This is referenced only by Firestore-backed services; on
/// sample data (`-ViFiMockData`) nothing touches it, so Firebase is never configured there.
enum ViFiFirestore {
    /// The named Native-mode database holding the archive (the `(default)` database is legacy Datastore mode).
    static let databaseID = "vifi"

    static let shared: Firestore = {
        let firestore = Firestore.firestore(database: databaseID)
        let settings = FirestoreSettings()
        // Offline disk cache (replaces the deprecated `isPersistenceEnabled`); the default size is ample for
        // the small archive metadata.
        settings.cacheSettings = PersistentCacheSettings()
        firestore.settings = settings
        return firestore
    }()
}

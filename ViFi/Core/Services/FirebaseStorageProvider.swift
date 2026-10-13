@preconcurrency import FirebaseStorage
import Foundation

/// The single Cloud Storage instance for the app, using the project's default bucket (`vifi-831a8.appspot.com`).
///
/// Mirrors `ViFiFirestore` / `ViFiDatabase`: referenced only by Storage-backed services, so on sample data
/// (`-ViFiMockData`) nothing touches it and Firebase is never configured there. Uploads run under enforced App
/// Check, whose token the SDK attaches automatically once the provider is installed (done in `live()` before
/// `FirebaseApp.configure()`).
enum ViFiStorage {
    static let shared = Storage.storage()
}

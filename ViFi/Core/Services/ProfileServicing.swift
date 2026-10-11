import Foundation

/// Reads and stores the signed-in user's profile (`users/<uid>/profile`).
///
/// The live implementation requires a signed-in +90 user; database rules reject every other request.
/// Every throwing operation throws `ProfileError` (or `CancellationError`).
protocol ProfileServicing: AnyObject {
    /// The stored profile for `uid`, or `nil` when the user has not completed it yet.
    func loadProfile(uid: String) async throws -> UserProfile?

    /// Creates or replaces the profile for `uid`.
    func saveProfile(_ profile: UserProfile, uid: String) async throws
}

/// Profile errors, with messages shown to the user.
nonisolated enum ProfileError: LocalizedError, Equatable {
    /// Nobody is signed in, or the uid does not match the signed-in user.
    case notSignedIn
    /// Database rules rejected the read or write.
    case permissionDenied
    /// No connection or a timeout.
    case offline
    case unknown(message: String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            String(localized: "Oturumun sona erdi. Lütfen yeniden giriş yap.")
        case .permissionDenied:
            String(localized: "Profilin şu anda kaydedilemiyor. Lütfen daha sonra tekrar dene.")
        case .offline:
            String(localized: "İnternet bağlantısı yok. Bağlantını kontrol edip tekrar dene.")
        case let .unknown(message):
            message
        }
    }
}

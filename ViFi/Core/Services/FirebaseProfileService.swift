@preconcurrency import FirebaseDatabase
import Foundation
import os

/// Reads and writes the signed-in user's profile in the Firebase Realtime Database (`users/<uid>/profile`).
///
/// Reading and writing require a signed-in +90 user; the rules reject everything else. A read is answered
/// from the on-disk cache first when offline. The node is tiny (six fields), so parsing it inside the
/// Firebase callback — where the non-sendable `DataSnapshot` stays — is cheap.
final class FirebaseProfileService: ProfileServicing {
    private static let rootKey = "users"
    private static let profileKey = "profile"

    /// The shared database, configured once by `ViFiDatabase` before its first reference is created.
    private static var database: Database { ViFiDatabase.shared }

    private let root: DatabaseReference
    private let auth: any AuthServicing
    private let timeout: Duration

    /// - Parameters:
    ///   - auth: The sign-in state; the uid of a write is checked against the signed-in user.
    ///   - timeout: How long an operation may wait before failing with `ProfileError.offline`.
    init(auth: any AuthServicing, timeout: Duration = .seconds(15)) {
        self.auth = auth
        self.timeout = timeout
        root = Self.database.reference(withPath: Self.rootKey)
    }

    func loadProfile(uid: String) async throws -> UserProfile? {
        let reference = root.child(uid).child(Self.profileKey)
        let outcome = FirstOutcome<UserProfile?>()
        let timeoutTask = Task { [timeout] in
            try await Task.sleep(for: timeout)
            outcome.resolve(.failure(ProfileError.offline))
        }
        defer { timeoutTask.cancel() }

        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UserProfile?, any Error>) in
                    outcome.attach(continuation)
                    reference.observeSingleEvent(
                        of: .value,
                        with: { @Sendable snapshot in
                            outcome.resolve(.success(UserProfileParser.profile(from: snapshot.value)))
                        },
                        withCancel: { @Sendable error in
                            outcome.resolve(.failure(Self.profileError(fromCancellation: error)))
                        }
                    )
                }
            } onCancel: {
                outcome.resolve(.failure(CancellationError()))
            }
        } catch {
            Self.log(error, during: "Loading the profile")
            throw error
        }
    }

    func saveProfile(_ profile: UserProfile, uid: String) async throws {
        // The uid must be the signed-in user; the rules enforce this too, but failing early avoids a round trip.
        guard auth.currentUser?.id == uid else { throw ProfileError.notSignedIn }

        let reference = root.child(uid).child(Self.profileKey)
        var values = UserProfileParser.fields(of: profile)
        values["updatedAt"] = ServerValue.timestamp()
        let outcome = FirstOutcome<Void>()
        let timeoutTask = Task { [timeout] in
            try await Task.sleep(for: timeout)
            outcome.resolve(.failure(ProfileError.offline))
        }
        defer { timeoutTask.cancel() }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    outcome.attach(continuation)
                    reference.updateChildValues(values) { @Sendable error, _ in
                        if let error {
                            outcome.resolve(.failure(Self.profileError(from: error)))
                        } else {
                            outcome.resolve(.success(()))
                        }
                    }
                }
            } onCancel: {
                outcome.resolve(.failure(CancellationError()))
            }
        } catch {
            Self.log(error, during: "Saving the profile")
            throw error
        }
    }
}

// MARK: - Error mapping

extension FirebaseProfileService {
    /// Firebase reports a rejected operation with this domain and code (`permission_denied`).
    private nonisolated static let firebaseErrorDomain = "com.firebase"
    private nonisolated static let permissionDeniedCode = 1

    /// Maps an error thrown by a database write to a `ProfileError`.
    nonisolated static func profileError(from error: any Error) -> ProfileError {
        if let error = error as? ProfileError { return error }
        let error = error as NSError
        if error.domain == NSURLErrorDomain { return .offline }
        return isPermissionDenied(error) ? .permissionDenied : .unknown(message: genericErrorMessage)
    }

    /// Maps the error a read listener is cancelled with to a `ProfileError`.
    nonisolated static func profileError(fromCancellation error: any Error) -> ProfileError {
        let error = error as NSError
        return isPermissionDenied(error) ? .permissionDenied : .unknown(message: error.localizedDescription)
    }

    private nonisolated static func isPermissionDenied(_ error: NSError) -> Bool {
        (error.domain == firebaseErrorDomain && error.code == permissionDeniedCode)
            || error.localizedDescription.localizedCaseInsensitiveContains("permission")
    }

    private static func log(_ error: any Error, during operation: String) {
        guard !(error is CancellationError) else { return }
        let reason = String(describing: error)
        Logger.app.error("\(operation, privacy: .public) failed: \(reason, privacy: .public)")
    }

    nonisolated static var genericErrorMessage: String {
        String(localized: "Bir sorun oluştu. Lütfen tekrar dene.")
    }
}

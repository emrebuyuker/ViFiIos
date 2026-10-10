@preconcurrency import FirebaseAppCheck
@preconcurrency import FirebaseAuth
import Foundation
import os

/// Authorizes Firebase Storage downloads the way the Storage SDK does: the user's ID token in
/// `Authorization: Firebase <token>` and the App Check token in `X-Firebase-AppCheck`.
///
/// Files are fetched by their canonical URL, never by the `token=` query parameter of the stored
/// download URLs, so Storage rules (signed-in user, App Check) decide every download.
///
/// Like the Storage SDK, credentials only go to the app's own bucket: a download URL naming any other
/// bucket is refused rather than sent the user's tokens.
final class FirebaseRequestAuthorizer: RequestAuthorizing {
    private let auth: Auth
    private let appCheck: AppCheck?
    private let storageBucket: String?

    /// - Parameters:
    ///   - auth: The configured `Auth` instance.
    ///   - appCheck: The configured App Check instance; `nil` sends requests without an App Check token.
    ///   - storageBucket: The app's Storage bucket (`FirebaseOptions.storageBucket`), the only one authorized.
    init(auth: Auth, appCheck: AppCheck?, storageBucket: String?) {
        self.auth = auth
        self.appCheck = appCheck
        self.storageBucket = storageBucket
    }

    func authorizedRequest(for url: URL, forceRefresh: Bool) async throws -> URLRequest {
        guard let storageBucket, Self.isObject(url, inBucket: storageBucket) else {
            Logger.files.error("Refusing to authorize \(url, privacy: .private): not in the app's Storage bucket")
            throw ArchiveError.permissionDenied
        }
        guard let user = auth.currentUser else { throw ArchiveError.permissionDenied }

        let idToken: String
        do {
            idToken = try await user.getIDToken(forcingRefresh: forceRefresh)
        } catch {
            let reason = String(describing: error)
            Logger.files.error("Fetching the ID token failed: \(reason, privacy: .public)")
            let authError = FirebaseAuthService.authError(from: error as NSError)
            throw authError == .offline ? ArchiveError.offline : ArchiveError.permissionDenied
        }

        var request = URLRequest(url: url)
        request.setValue("Firebase \(idToken)", forHTTPHeaderField: "Authorization")
        if let appCheckToken = await appCheckToken() {
            request.setValue(appCheckToken, forHTTPHeaderField: "X-Firebase-AppCheck")
        }
        return request
    }

    /// Whether `url` is a Firebase Storage download URL of an object in `bucket` (`/v0/b/<bucket>/o/…`).
    nonisolated static func isObject(_ url: URL, inBucket bucket: String) -> Bool {
        !bucket.isEmpty
            && RemoteFileLoader.isFirebaseStorageURL(url)
            && url.path(percentEncoded: true).hasPrefix("/v0/b/\(bucket)/o/")
    }

    /// The cached App Check token, refreshed by the SDK before it expires.
    ///
    /// Never force-refreshed here: a rejected download is far more often a rules or ID token problem, and
    /// every forced refresh costs an App Attest / DeviceCheck round trip with a strict quota. A missing
    /// token is logged and the request is sent without it; enforcement then rejects it like the SDK would.
    private func appCheckToken() async -> String? {
        guard let appCheck else { return nil }
        do {
            return try await appCheck.token(forcingRefresh: false).token
        } catch {
            let reason = String(describing: error)
            Logger.files.error("Fetching the App Check token failed: \(reason, privacy: .public)")
            return nil
        }
    }
}

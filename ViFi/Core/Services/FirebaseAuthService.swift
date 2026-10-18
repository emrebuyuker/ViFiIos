@preconcurrency import FirebaseAuth
import FirebaseCore
import Foundation
import os

/// Phone number sign-in with Firebase Authentication.
///
/// The SMS code is only sent once Firebase has verified the app: with a silent push (APNs token and
/// notifications are forwarded by `AppDelegate`), or else with a reCAPTCHA page that returns through the
/// encoded app id URL scheme (forwarded by `RootView.onOpenURL`).
final class FirebaseAuthService: AuthServicing {
    private let auth: Auth

    /// `Auth.auth()` once Firebase is configured, `nil` before that and on sample data (`-ViFiMockData`),
    /// where Firebase is never configured and `Auth.auth()` would crash.
    static var configuredAuth: Auth? {
        FirebaseApp.app() == nil ? nil : Auth.auth()
    }

    /// - Parameters:
    ///   - auth: The configured `Auth` instance.
    ///   - arguments: Launch arguments; Debug builds honour `-ViFiPhoneAuthTesting`.
    init(auth: Auth, arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.auth = auth
        // SMS texts and the reCAPTCHA page in Turkish.
        auth.languageCode = "tr"

        #if DEBUG
        if arguments.contains(LaunchArgument.phoneAuthTesting) {
            // Skips APNs/reCAPTCHA app verification. Works only with the console's fictional test numbers.
            auth.settings?.isAppVerificationDisabledForTesting = true
            Logger.app.notice("Phone auth app verification is disabled for testing")
        }
        #endif
    }

    var currentUser: AuthUser? {
        auth.currentUser.map(AuthUser.init)
    }

    func userChanges() -> AsyncStream<AuthUser?> {
        // `Auth` and the listener handle are thread-safe but not annotated `Sendable`.
        nonisolated(unsafe) let auth = auth
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            // Invoked on the main thread: right away with the restored user, then on every sign-in and sign-out.
            let handle = auth.addStateDidChangeListener { _, user in
                continuation.yield(user.map(AuthUser.init))
            }
            nonisolated(unsafe) let listenerHandle = handle
            continuation.onTermination = { @Sendable _ in
                auth.removeStateDidChangeListener(listenerHandle)
            }
        }
    }

    func isCurrentUserAdmin() async -> Bool {
        guard let user = auth.currentUser else { return false }
        do {
            // A forced refresh picks up a claim granted during this session; Firebase caches the token otherwise.
            let result = try await user.getIDTokenResult(forcingRefresh: false)
            return result.claims["admin"] as? Bool == true
        } catch {
            Logger.app.error("Reading admin claim failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    func sendVerificationCode(to phoneNumber: String) async throws -> String {
        // Firebase stops the app with `fatalError` when the reCAPTCHA return scheme is missing; fail gracefully.
        guard isRecaptchaCallbackSchemeRegistered else {
            Logger.app.fault("The phone auth reCAPTCHA URL scheme is missing from Info.plist")
            throw AuthError.appVerificationFailed
        }
        do {
            return try await PhoneAuthProvider.provider(auth: auth).verifyPhoneNumber(phoneNumber, uiDelegate: nil)
        } catch {
            throw Self.authError(from: error, during: "Sending the verification code")
        }
    }

    @discardableResult
    func signIn(verificationID: String, code: String) async throws -> AuthUser {
        let credential = credential(verificationID: verificationID, code: code)
        do {
            let result = try await auth.signIn(with: credential)
            return AuthUser(result.user)
        } catch {
            throw Self.authError(from: error, during: "Signing in")
        }
    }

    func reauthenticate(verificationID: String, code: String) async throws {
        guard let user = auth.currentUser else { throw AuthError.notSignedIn }
        let credential = credential(verificationID: verificationID, code: code)
        do {
            _ = try await user.reauthenticate(with: credential)
        } catch {
            throw Self.authError(from: error, during: "Reauthenticating")
        }
    }

    func signOut() throws {
        do {
            try auth.signOut()
        } catch {
            throw Self.authError(from: error, during: "Signing out")
        }
    }

    func deleteAccount() async throws {
        guard let user = auth.currentUser else { throw AuthError.notSignedIn }
        do {
            try await user.delete()
        } catch {
            throw Self.authError(from: error, during: "Deleting the account")
        }
    }

    func canHandle(_ url: URL) -> Bool {
        auth.canHandle(url)
    }

    // MARK: - Private

    private func credential(verificationID: String, code: String) -> PhoneAuthCredential {
        PhoneAuthProvider.provider(auth: auth).credential(withVerificationID: verificationID, verificationCode: code)
    }

    /// Whether Info.plist registers `app-<GOOGLE_APP_ID with dashes>` (or the reversed client id), the scheme
    /// the reCAPTCHA fallback returns to.
    private var isRecaptchaCallbackSchemeRegistered: Bool {
        let options = auth.app?.options
        var accepted: Set<String> = []
        if let appID = options?.googleAppID {
            accepted.insert("app-" + appID.replacingOccurrences(of: ":", with: "-"))
        }
        if let clientID = options?.clientID {
            accepted.insert(clientID.components(separatedBy: ".").reversed().joined(separator: "."))
        }
        let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        let registered = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        return registered.contains { scheme in
            accepted.contains { $0.caseInsensitiveCompare(scheme) == .orderedSame }
        }
    }
}

// MARK: - Mapping

private extension AuthUser {
    init(_ user: User) {
        self.init(id: user.uid, phoneNumber: user.phoneNumber)
    }
}

extension FirebaseAuthService {
    /// Maps a Firebase Auth error to the errors the UI presents, logging the original.
    static func authError(from error: any Error, during operation: String) -> any Error {
        if error is CancellationError || error is AuthError {
            return error
        }
        let mapped = authError(from: error as NSError)
        let reason = String(describing: error)
        Logger.app.error("\(operation, privacy: .public) failed: \(reason, privacy: .public)")
        return mapped
    }

    nonisolated static func authError(from error: NSError) -> AuthError {
        if isSMSTemporarilyUnavailable(error) {
            return .smsTemporarilyUnavailable
        }
        guard error.domain == AuthErrors.domain, let code = AuthErrorCode(rawValue: error.code) else {
            return error.domain == NSURLErrorDomain ? .offline : .unknown(message: genericErrorMessage)
        }
        switch code {
        case .invalidPhoneNumber, .missingPhoneNumber:
            return .invalidPhoneNumber
        case .invalidVerificationCode, .missingVerificationCode:
            return .invalidCode
        case .sessionExpired, .invalidVerificationID, .missingVerificationID:
            return .codeExpired
        case .tooManyRequests, .quotaExceeded:
            return .tooManyRequests
        case .networkError, .webNetworkRequestFailed:
            return .offline
        case .webContextCancelled:
            return .verificationCancelled
        case .appNotVerified, .appNotAuthorized, .captchaCheckFailed, .missingAppCredential, .invalidAppCredential,
             .missingAppToken, .notificationNotForwarded, .webContextAlreadyPresented,
             .appVerificationUserInteractionFailure, .webSignInUserInteractionFailure, .webInternalError,
             .invalidClientID, .missingClientIdentifier, .missingClientType, .missingRecaptchaToken,
             .invalidRecaptchaToken, .invalidRecaptchaAction, .missingRecaptchaVersion, .invalidRecaptchaVersion,
             .recaptchaNotEnabled, .recaptchaSiteKeyMissing, .recaptchaActionCreationFailed, .recaptchaSDKNotLinked:
            return .appVerificationFailed
        case .requiresRecentLogin:
            return .requiresRecentLogin
        case .userDisabled:
            return .accountDisabled
        case .userTokenExpired, .invalidUserToken, .userNotFound, .nullUser:
            return .notSignedIn
        default:
            return .unknown(message: genericErrorMessage)
        }
    }

    nonisolated static var genericErrorMessage: String {
        String(localized: "Bir sorun oluştu. Lütfen tekrar dene.")
    }

    /// Key Firebase uses for the raw backend error body it tucks inside an `internalError`'s user info.
    private nonisolated static let backendDeserializedResponseKey = "FIRAuthErrorUserInfoDeserializedResponseKey"
    /// Google's SMS anti-abuse rejection. It reaches the client as a generic `internalError` (`17999`) with the
    /// real cause ("Error code: 39", HTTP 503) buried in the deserialized backend response.
    private nonisolated static let smsAntiAbuseBackendCode = 39

    /// Whether `error` is the SMS anti-abuse rejection the backend reports as "Error code: 39". Firebase maps it
    /// to a vague `internalError`, so we dig the backend code out of the deserialized response (and its
    /// `NSUnderlyingError` ancestors) to tell the user it is a temporary SMS outage rather than "something broke".
    nonisolated static func isSMSTemporarilyUnavailable(_ error: NSError) -> Bool {
        errorChain(from: error).contains { nsError in
            guard let response = nsError.userInfo[backendDeserializedResponseKey] as? [String: Any] else {
                return false
            }
            return backendErrorCode(in: response) == smsAntiAbuseBackendCode
        }
    }

    /// `error` together with its `NSUnderlyingError` ancestors, capped so a cyclic chain can never loop forever.
    private nonisolated static func errorChain(from error: NSError) -> [NSError] {
        var chain: [NSError] = []
        var current: NSError? = error
        while let nsError = current, chain.count < 8 {
            chain.append(nsError)
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return chain
    }

    /// The numeric code in a deserialized backend error whose message reads e.g. "Error code: 39", checking both
    /// the top-level `message` and any nested `errors` entries.
    private nonisolated static func backendErrorCode(in response: [String: Any]) -> Int? {
        var messages: [String] = []
        if let message = response["message"] as? String {
            messages.append(message)
        }
        if let errors = response["errors"] as? [[String: Any]] {
            messages.append(contentsOf: errors.compactMap { $0["message"] as? String })
        }
        return messages.lazy.compactMap(parsedBackendErrorCode(from:)).first
    }

    private nonisolated static func parsedBackendErrorCode(from message: String) -> Int? {
        let lowercased = message.lowercased()
        guard let marker = lowercased.range(of: "error code:") else { return nil }
        let digits = lowercased[marker.upperBound...]
            .drop { $0 == " " }
            .prefix { $0.isNumber }
        return Int(digits)
    }
}

import Foundation

/// The signed-in user, as the app sees it.
nonisolated struct AuthUser: Hashable, Sendable {
    /// The Firebase user id (`auth.uid` in security rules).
    let id: String
    /// The verified number in E.164 format (`+905321234567`); `nil` only for accounts without one.
    let phoneNumber: String?

    /// `+90 532 123 45 67`, or the raw value when it is not a Turkish number.
    var formattedPhoneNumber: String? {
        guard let phoneNumber else { return nil }
        return PhoneNumber(e164: phoneNumber)?.formatted ?? phoneNumber
    }
}

/// Signs the user in with their phone number (SMS one-time code) and manages the account.
///
/// The whole app requires a signed-in user: database and file rules reject anonymous requests.
/// Every throwing operation throws `AuthError` (or `CancellationError`).
protocol AuthServicing: AnyObject {
    /// The signed-in user, if any. May be `nil` briefly at launch until the stored session is restored;
    /// `userChanges()` reports the authoritative state.
    var currentUser: AuthUser? { get }

    /// Emits the current user right away and again on every sign-in and sign-out; the stream ends when the
    /// consuming task is cancelled.
    func userChanges() -> AsyncStream<AuthUser?>

    /// Sends a verification code by SMS to `phoneNumber` (E.164) and returns the verification id that the code
    /// must be combined with.
    func sendVerificationCode(to phoneNumber: String) async throws -> String

    /// Signs in with a code sent by `sendVerificationCode(to:)`.
    @discardableResult
    func signIn(verificationID: String, code: String) async throws -> AuthUser

    /// Confirms the signed-in user's identity again with a fresh code, before a sensitive operation.
    func reauthenticate(verificationID: String, code: String) async throws

    func signOut() throws

    /// Permanently deletes the signed-in user's account. Throws `AuthError.requiresRecentLogin` when the
    /// last sign-in is too old; reauthenticate and try again.
    func deleteAccount() async throws

    /// Whether `url` is the reCAPTCHA verification redirect of phone sign-in (and was consumed by it).
    func canHandle(_ url: URL) -> Bool
}

/// Sign-in and account errors, with messages shown to the user.
nonisolated enum AuthError: LocalizedError, Equatable {
    case invalidPhoneNumber
    case invalidCode
    /// The code or the verification session expired; a new code is needed.
    case codeExpired
    /// Too many attempts from this device or number, or the SMS quota is exhausted.
    case tooManyRequests
    case offline
    /// The user closed the reCAPTCHA page.
    case verificationCancelled
    /// The app could not prove it is genuine (APNs, reCAPTCHA or App Check).
    case appVerificationFailed
    /// The operation needs a recent sign-in; verify the number again.
    case requiresRecentLogin
    /// The user is no longer signed in (e.g. the account was deleted elsewhere).
    case notSignedIn
    /// An admin disabled the account; signing in again will not help.
    case accountDisabled
    case unknown(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidPhoneNumber:
            String(localized: "Telefon numarası geçersiz. 5 ile başlayan 10 haneli cep telefonu numaranı gir.")
        case .invalidCode:
            String(localized: "Kod hatalı. SMS ile gelen 6 haneli kodu kontrol edip tekrar dene.")
        case .codeExpired:
            String(localized: "Kodun süresi doldu. Yeni bir kod iste.")
        case .tooManyRequests:
            String(localized: "Çok fazla deneme yapıldı. Lütfen bir süre sonra tekrar dene.")
        case .offline:
            String(localized: "İnternet bağlantısı yok. Bağlantını kontrol edip tekrar dene.")
        case .verificationCancelled:
            String(localized: "Doğrulama iptal edildi. Kod almak için tekrar dene.")
        case .appVerificationFailed:
            String(localized: "Cihaz doğrulanamadı. Lütfen daha sonra tekrar dene.")
        case .requiresRecentLogin:
            String(localized: "Güvenliğin için numaranı yeniden doğrulaman gerekiyor.")
        case .notSignedIn:
            String(localized: "Oturumun sona erdi. Lütfen yeniden giriş yap.")
        case .accountDisabled:
            String(localized: "Bu hesap devre dışı bırakıldı.")
        case let .unknown(message):
            message
        }
    }
}

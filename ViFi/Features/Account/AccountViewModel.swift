import Foundation
import Observation

/// The signed-in account: sign out, or delete it permanently.
///
/// Deleting needs a recent sign-in. When Firebase asks for one, a code is sent to the same number; once it
/// is confirmed the account is reauthenticated and deleted. Either way the session gate then shows the login
/// screen. Tasks hold the model weakly, like `LoginViewModel`'s.
@Observable
final class AccountViewModel {
    let user: AuthUser

    private(set) var isWorking = false
    private(set) var errorMessage: String?
    /// Whether the number is being verified again before deletion (the code entry is shown).
    private(set) var isReverifying = false
    /// The re-verification code as typed; digits only, at most six (`updateCode(_:)`).
    private(set) var codeText = ""
    /// When the cooldown after the last re-verification code ends.
    private(set) var resendAvailableAt: Date?

    @ObservationIgnored private let auth: any AuthServicing
    @ObservationIgnored private let now: () -> Date
    /// Removes the user's stored data (their profile) while they are still signed in, before the account is
    /// deleted — so a deleted account leaves nothing behind. Throws to abort the deletion.
    @ObservationIgnored private let deleteUserData: @MainActor () async throws -> Void
    /// Run once the account has been deleted, to wipe the user's locally cached exam data.
    @ObservationIgnored private let onDeleted: @MainActor () async -> Void
    @ObservationIgnored private var verificationID: String?

    /// - Parameters:
    ///   - now: The clock the resend cooldown is measured with (injected by tests).
    ///   - deleteUserData: Removes the user's server-side data (profile) before the account is deleted.
    ///   - onDeleted: Called after a successful deletion, to purge locally cached exam files.
    init(
        user: AuthUser,
        auth: any AuthServicing,
        now: @escaping () -> Date = Date.init,
        deleteUserData: @escaping @MainActor () async throws -> Void = {},
        onDeleted: @escaping @MainActor () async -> Void = {}
    ) {
        self.user = user
        self.auth = auth
        self.now = now
        self.deleteUserData = deleteUserData
        self.onDeleted = onDeleted
    }

    /// `+90 532 123 45 67`.
    var formattedPhoneNumber: String {
        user.formattedPhoneNumber ?? String(localized: "Telefon numarası yok")
    }

    var canConfirmReverification: Bool {
        isReverifying && codeText.count == VerificationCode.length && verificationID != nil && !isWorking
    }

    /// Whole seconds left until another code can be requested, `0` once it can.
    func resendCooldownRemaining(at date: Date) -> Int {
        guard let resendAvailableAt else { return 0 }
        return max(0, Int(resendAvailableAt.timeIntervalSince(date).rounded(.up)))
    }

    func canResendCode(at date: Date) -> Bool {
        isReverifying && !isWorking && resendCooldownRemaining(at: date) == 0
    }

    // MARK: - Actions

    func signOut() {
        guard !isWorking else { return }
        do {
            try auth.signOut()
        } catch {
            errorMessage = error.userMessage
        }
    }

    /// Deletes the account, verifying the number again first when Firebase requires a recent sign-in.
    @discardableResult
    func deleteAccount() -> Task<Void, Never>? {
        guard !isWorking else { return nil }
        isWorking = true
        errorMessage = nil
        let auth = auth
        let phoneNumber = user.phoneNumber
        let deleteUserData = deleteUserData
        let onDeleted = onDeleted
        return Task { [weak self] in
            do {
                // Remove the profile while still signed in, so a deleted account leaves nothing behind.
                try await deleteUserData()
                try await auth.deleteAccount()
                // Runs even if the sheet is already torn down by the session gate; captured, not via `self`.
                await onDeleted()
            } catch AuthError.requiresRecentLogin {
                // No SMS once the sheet is gone: nothing could take the code any more.
                guard self != nil, !Task.isCancelled else { return }
                do {
                    let verificationID = try await Self.sendReverificationCode(using: auth, to: phoneNumber)
                    self?.didSendReverificationCode(verificationID: verificationID)
                } catch {
                    self?.fail(with: error)
                }
            } catch {
                self?.fail(with: error)
            }
        }
    }

    /// Takes an edit of the code field: digits only, at most six, confirmed as soon as all six are there
    /// (typed or autofilled).
    @discardableResult
    func updateCode(_ input: String) -> Task<Void, Never>? {
        guard !isWorking else { return nil }
        codeText = VerificationCode.digits(from: input)
        guard !codeText.isEmpty else { return nil }
        errorMessage = nil
        return codeText.count == VerificationCode.length ? confirmReverification() : nil
    }

    /// Reauthenticates with the entered code, then deletes the account.
    @discardableResult
    func confirmReverification() -> Task<Void, Never>? {
        guard canConfirmReverification, let verificationID else { return nil }
        isWorking = true
        errorMessage = nil
        let auth = auth
        let code = codeText
        let onDeleted = onDeleted
        return Task { [weak self] in
            do {
                try await auth.reauthenticate(verificationID: verificationID, code: code)
                // The profile was already removed by `deleteAccount()` before the recent-login prompt.
                try await auth.deleteAccount()
                await onDeleted()
            } catch {
                self?.fail(with: error)
            }
        }
    }

    /// Sends a new re-verification code once the cooldown is over.
    @discardableResult
    func resendCode() -> Task<Void, Never>? {
        guard canResendCode(at: now()) else { return nil }
        isWorking = true
        errorMessage = nil
        let auth = auth
        let phoneNumber = user.phoneNumber
        return Task { [weak self] in
            do {
                let verificationID = try await Self.sendReverificationCode(using: auth, to: phoneNumber)
                self?.didSendReverificationCode(verificationID: verificationID)
            } catch {
                self?.fail(with: error)
            }
        }
    }

    func cancelReverification() {
        guard !isWorking else { return }
        isReverifying = false
        verificationID = nil
        codeText = ""
        errorMessage = nil
        resendAvailableAt = nil
    }

    // MARK: - Private

    /// Sends a code to the account's own number (E.164, as Firebase reports it).
    private static func sendReverificationCode(using auth: any AuthServicing, to phoneNumber: String?) async throws -> String {
        guard let phoneNumber else { throw AuthError.requiresRecentLogin }
        return try await auth.sendVerificationCode(to: phoneNumber)
    }

    /// Shows the code entry for the code just sent.
    private func didSendReverificationCode(verificationID: String) {
        self.verificationID = verificationID
        isReverifying = true
        codeText = ""
        resendAvailableAt = now().addingTimeInterval(LoginViewModel.resendCooldown)
        isWorking = false
    }

    private func fail(with error: any Error) {
        isWorking = false
        guard !(error is CancellationError) else { return }
        errorMessage = error.userMessage

        switch error as? AuthError {
        case .invalidCode:
            codeText = ""
        case .codeExpired:
            codeText = ""
            resendAvailableAt = nil
        default:
            break
        }
    }
}

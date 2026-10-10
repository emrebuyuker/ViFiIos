import Foundation
import Observation

/// Phone number sign-in: enter the number, then the six-digit code sent by SMS.
///
/// Work runs in tasks the model owns and returns (so tests can await them). They hold the model weakly:
/// once the screen is gone — typically because sign-in succeeded and the session gate took over — results
/// are dropped instead of updating a model nobody shows.
@Observable
final class LoginViewModel {
    enum Step: Equatable {
        case phone
        /// A code was sent to the number.
        case code(PhoneNumber)
    }

    /// Seconds before another code can be requested for the same number.
    static let resendCooldown: TimeInterval = 60

    private(set) var step: Step = .phone
    /// The number as typed, formatted as `5XX XXX XX XX` (`updatePhoneText(_:)`).
    private(set) var phoneText = ""
    /// The code as typed; digits only, at most six (`updateCode(_:)`).
    private(set) var codeText = ""
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    /// When the cooldown after the last sent code ends.
    private(set) var resendAvailableAt: Date?

    @ObservationIgnored private let auth: any AuthServicing
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var verificationID: String?
    /// The last code sent, kept across `changeNumber()` so re-entering the same number cannot skip the cooldown.
    @ObservationIgnored private var lastSentCode: SentCode?

    /// - Parameter now: The clock the resend cooldown is measured with (injected by tests).
    init(auth: any AuthServicing, now: @escaping () -> Date = Date.init) {
        self.auth = auth
        self.now = now
    }

    /// The typed number, once it is a complete Turkish mobile number.
    var phoneNumber: PhoneNumber? {
        PhoneNumber(input: phoneText)
    }

    var canSendCode: Bool {
        phoneNumber != nil && !isWorking
    }

    var canVerify: Bool {
        codeText.count == VerificationCode.length && verificationID != nil && !isWorking
    }

    /// Whole seconds left until another code can be requested, `0` once it can.
    func resendCooldownRemaining(at date: Date) -> Int {
        guard let resendAvailableAt else { return 0 }
        return max(0, Int(resendAvailableAt.timeIntervalSince(date).rounded(.up)))
    }

    func canResendCode(at date: Date) -> Bool {
        guard case .code = step else { return false }
        return !isWorking && resendCooldownRemaining(at: date) == 0
    }

    // MARK: - Input

    /// Takes an edit of the number field, formatted so pasted `+90 5…` or `05…` numbers end up as `5XX XXX XX XX`.
    func updatePhoneText(_ input: String) {
        guard !isWorking else { return }
        phoneText = PhoneNumber.formattedInput(input)
        if !phoneText.isEmpty {
            errorMessage = nil
        }
    }

    /// Takes an edit of the code field: digits only, at most six, submitted as soon as all six are there
    /// (typed or autofilled).
    @discardableResult
    func updateCode(_ input: String) -> Task<Void, Never>? {
        guard !isWorking else { return nil }
        codeText = VerificationCode.digits(from: input)
        guard !codeText.isEmpty else { return nil }
        errorMessage = nil
        return codeText.count == VerificationCode.length ? verifyCode() : nil
    }

    // MARK: - Actions

    /// Sends a code to the typed number. Ignored while another request is running. Within the cooldown of a
    /// code already sent to the same number, that code's entry is shown again instead of sending another SMS.
    @discardableResult
    func sendCode() -> Task<Void, Never>? {
        guard !isWorking, let phoneNumber else { return nil }
        if let lastSentCode, lastSentCode.phoneNumber == phoneNumber, now() < lastSentCode.resendAvailableAt {
            showCodeStep(for: lastSentCode)
            return nil
        }
        return requestCode(for: phoneNumber)
    }

    /// Sends a new code to the same number once the cooldown is over.
    @discardableResult
    func resendCode() -> Task<Void, Never>? {
        guard case let .code(phoneNumber) = step, canResendCode(at: now()) else { return nil }
        return requestCode(for: phoneNumber)
    }

    /// Signs in with the entered code. On success the session gate replaces the login screen, so the model
    /// stays busy until then.
    @discardableResult
    func verifyCode() -> Task<Void, Never>? {
        guard canVerify, let verificationID else { return nil }
        isWorking = true
        errorMessage = nil
        let auth = auth
        let code = codeText
        return Task { [weak self] in
            do {
                try await auth.signIn(verificationID: verificationID, code: code)
            } catch {
                self?.fail(with: error)
            }
        }
    }

    /// Back to the number step, keeping the typed number for editing.
    func changeNumber() {
        guard !isWorking else { return }
        step = .phone
        verificationID = nil
        codeText = ""
        errorMessage = nil
        resendAvailableAt = nil
    }

    // MARK: - Private

    private func requestCode(for phoneNumber: PhoneNumber) -> Task<Void, Never> {
        isWorking = true
        errorMessage = nil
        let auth = auth
        return Task { [weak self] in
            do {
                let verificationID = try await auth.sendVerificationCode(to: phoneNumber.e164)
                self?.didSendCode(to: phoneNumber, verificationID: verificationID)
            } catch {
                self?.fail(with: error)
            }
        }
    }

    private func didSendCode(to phoneNumber: PhoneNumber, verificationID: String) {
        let sentCode = SentCode(
            phoneNumber: phoneNumber,
            verificationID: verificationID,
            resendAvailableAt: now().addingTimeInterval(Self.resendCooldown)
        )
        lastSentCode = sentCode
        showCodeStep(for: sentCode)
        isWorking = false
    }

    private func showCodeStep(for sentCode: SentCode) {
        verificationID = sentCode.verificationID
        step = .code(sentCode.phoneNumber)
        codeText = ""
        errorMessage = nil
        resendAvailableAt = sentCode.resendAvailableAt
    }

    private func fail(with error: any Error) {
        isWorking = false
        guard !(error is CancellationError) else { return }
        errorMessage = error.userMessage

        switch error as? AuthError {
        case .invalidCode:
            // Ready for the next attempt; the message stays until the user types again.
            codeText = ""
        case .codeExpired:
            // The code is useless now; a new one may be requested right away.
            codeText = ""
            resendAvailableAt = nil
            lastSentCode = nil
        default:
            break
        }
    }
}

/// A code sent by SMS, and when another may be requested for the same number.
private nonisolated struct SentCode {
    let phoneNumber: PhoneNumber
    let verificationID: String
    let resendAvailableAt: Date
}

import Foundation
import Testing
@testable import ViFi

@Suite("AccountViewModel", .timeLimit(.minutes(1)))
struct AccountViewModelTests {
    private let auth = StubAuthService(currentUser: Fixture.user)
    private let clock = TestClock()

    // MARK: - Display

    @Test("The number is shown formatted")
    func formattedNumber() {
        let viewModel = makeViewModel()

        #expect(viewModel.formattedPhoneNumber == "+90 532 123 45 67")
        #expect(!viewModel.isWorking)
        #expect(!viewModel.isReverifying)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("An account without a number says so")
    func missingNumber() {
        let viewModel = makeViewModel(user: AuthUser(id: "user-2", phoneNumber: nil))

        #expect(viewModel.formattedPhoneNumber == String(localized: "Telefon numarası yok"))
    }

    // MARK: - Signing out

    @Test("Signing out ends the session")
    func signOut() {
        let viewModel = makeViewModel()

        viewModel.signOut()

        #expect(auth.calls == [.signOut])
        #expect(auth.currentUser == nil)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("A failed sign-out shows the message and keeps the session")
    func signOutFailure() {
        auth.signOutError = AuthError.unknown(message: "Çıkış yapılamadı.")
        let viewModel = makeViewModel()

        viewModel.signOut()

        #expect(viewModel.errorMessage == "Çıkış yapılamadı.")
        #expect(auth.currentUser == Fixture.user)
    }

    @Test("Signing out is ignored while the account is being deleted")
    func signOutWhileDeleting() async throws {
        let gate = AsyncGate()
        auth.gate = gate
        let viewModel = makeViewModel()
        let task = try #require(viewModel.deleteAccount())
        await gate.waitForArrival()

        viewModel.signOut()
        #expect(auth.count(of: .signOut) == 0)

        gate.open()
        await task.value
    }

    // MARK: - Deleting

    @Test("Deleting the account signs the user out")
    func deleteSuccess() async {
        let viewModel = makeViewModel()

        await viewModel.deleteAccount()?.value

        #expect(auth.calls == [.deleteAccount])
        #expect(auth.currentUser == nil)
        #expect(viewModel.errorMessage == nil)
        #expect(!viewModel.isReverifying)
        // The session gate replaces the sheet, so the model stays busy rather than flashing the form again.
        #expect(viewModel.isWorking)
    }

    @Test("A failed deletion shows the message and can be retried", arguments: [
        AuthError.offline,
        .notSignedIn,
        .tooManyRequests,
        .unknown(message: "Bir sorun oluştu."),
    ])
    func deleteFailure(_ error: AuthError) async {
        auth.deleteReplies = [.failure(error), .success(())]
        let viewModel = makeViewModel()

        await viewModel.deleteAccount()?.value

        #expect(viewModel.errorMessage == error.errorDescription)
        #expect(!viewModel.isWorking)
        #expect(!viewModel.isReverifying)
        #expect(auth.currentUser == Fixture.user)

        await viewModel.deleteAccount()?.value

        #expect(auth.currentUser == nil)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("A cancelled deletion shows no error")
    func deleteCancelled() async {
        auth.deleteReplies = [.failure(CancellationError())]
        let viewModel = makeViewModel()

        await viewModel.deleteAccount()?.value

        #expect(viewModel.errorMessage == nil)
        #expect(!viewModel.isWorking)
    }

    @Test("A second tap while deleting is ignored")
    func doubleTapOnDelete() async throws {
        let gate = AsyncGate()
        auth.gate = gate
        let viewModel = makeViewModel()

        let first = try #require(viewModel.deleteAccount())
        await gate.waitForArrival()
        #expect(viewModel.isWorking)
        #expect(viewModel.deleteAccount() == nil)
        gate.open()
        await first.value

        #expect(auth.count(of: .deleteAccount) == 1)
    }

    @Test("A result that arrives after the sheet is gone is dropped")
    func resultAfterViewModelIsGone() async throws {
        let gate = AsyncGate()
        auth.gate = gate
        auth.deleteReplies = [.failure(AuthError.offline)]
        var viewModel: AccountViewModel? = makeViewModel()
        let task = try #require(viewModel?.deleteAccount())
        await gate.waitForArrival()
        weak let released = viewModel

        viewModel = nil
        #expect(released == nil, "An in-flight request must not keep the sheet's model alive")
        gate.open()
        await task.value

        #expect(auth.count(of: .deleteAccount) == 1)
    }

    // MARK: - Re-verification

    @Test("When Firebase wants a recent sign-in, a code is sent to the same number")
    func deleteRequiresRecentLogin() async {
        auth.deleteReplies = [.failure(AuthError.requiresRecentLogin)]
        let viewModel = makeViewModel()

        await viewModel.deleteAccount()?.value

        #expect(auth.calls == [.deleteAccount, .sendCode(phoneNumber: Fixture.phoneNumber)])
        #expect(viewModel.isReverifying)
        #expect(!viewModel.isWorking)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.codeText.isEmpty)
        #expect(viewModel.resendAvailableAt == clock.date.addingTimeInterval(LoginViewModel.resendCooldown))
        #expect(auth.currentUser == Fixture.user)
    }

    @Test("The code reauthenticates the user, then the account is deleted")
    func reverifyThenDelete() async throws {
        auth.deleteReplies = [.failure(AuthError.requiresRecentLogin), .success(())]
        let viewModel = makeViewModel()
        await viewModel.deleteAccount()?.value

        viewModel.updateCode("12345")
        #expect(!viewModel.canConfirmReverification)
        let task = try #require(viewModel.updateCode("123456"))
        await task.value

        #expect(auth.calls == [
            .deleteAccount,
            .sendCode(phoneNumber: Fixture.phoneNumber),
            .reauthenticate(verificationID: "verification-1", code: "123456"),
            .deleteAccount,
        ])
        #expect(auth.currentUser == nil)
        #expect(viewModel.errorMessage == nil)
    }

    @Test("Confirming needs all six digits")
    func confirmNeedsSixDigits() async {
        auth.deleteReplies = [.failure(AuthError.requiresRecentLogin)]
        let viewModel = makeViewModel()
        await viewModel.deleteAccount()?.value

        viewModel.updateCode("12345")

        #expect(!viewModel.canConfirmReverification)
        #expect(viewModel.confirmReverification() == nil)
        #expect(auth.count(of: .reauthenticate(verificationID: "verification-1", code: "12345")) == 0)
    }

    @Test("Confirming without a re-verification in progress does nothing")
    func confirmWithoutReverification() {
        let viewModel = makeViewModel()

        #expect(viewModel.confirmReverification() == nil)
        #expect(viewModel.updateCode("123456") == nil)
        #expect(!viewModel.canConfirmReverification)
        #expect(auth.calls.isEmpty)
    }

    @Test("A wrong code shows the message and does not delete anything")
    func reverifyWrongCode() async throws {
        auth.deleteReplies = [.failure(AuthError.requiresRecentLogin), .success(())]
        auth.reauthenticateReplies = [.failure(AuthError.invalidCode), .success(())]
        let viewModel = makeViewModel()
        await viewModel.deleteAccount()?.value

        await viewModel.updateCode("000000")?.value

        #expect(viewModel.errorMessage == AuthError.invalidCode.errorDescription)
        #expect(viewModel.codeText.isEmpty)
        #expect(!viewModel.isWorking)
        #expect(viewModel.isReverifying, "The code entry stays for another try")
        #expect(auth.count(of: .deleteAccount) == 1, "The account is only deleted after a successful reauthentication")
        #expect(auth.currentUser == Fixture.user)

        let retry = try #require(viewModel.updateCode("111111"))
        #expect(viewModel.errorMessage == nil)
        await retry.value

        #expect(auth.currentUser == nil)
        #expect(auth.count(of: .deleteAccount) == 2)
    }

    @Test("An expired code allows a new one at once")
    func reverifyExpiredCode() async {
        auth.deleteReplies = [.failure(AuthError.requiresRecentLogin)]
        auth.reauthenticateReplies = [.failure(AuthError.codeExpired)]
        let viewModel = makeViewModel()
        await viewModel.deleteAccount()?.value
        #expect(!viewModel.canResendCode(at: clock.date))

        await viewModel.updateCode("123456")?.value

        #expect(viewModel.errorMessage == AuthError.codeExpired.errorDescription)
        #expect(viewModel.codeText.isEmpty)
        #expect(viewModel.resendAvailableAt == nil)
        #expect(viewModel.canResendCode(at: clock.date))
    }

    @Test("If the account still cannot be deleted after reauthenticating, the failure is shown")
    func deleteFailsAfterReauthentication() async {
        auth.deleteReplies = [.failure(AuthError.requiresRecentLogin), .failure(AuthError.offline)]
        let viewModel = makeViewModel()
        await viewModel.deleteAccount()?.value

        await viewModel.updateCode("123456")?.value

        #expect(viewModel.errorMessage == AuthError.offline.errorDescription)
        #expect(!viewModel.isWorking)
        #expect(auth.currentUser == Fixture.user)
    }

    @Test("An account without a number cannot be verified again")
    func reverifyWithoutNumber() async {
        let noNumber = AuthUser(id: "user-2", phoneNumber: nil)
        auth.deleteReplies = [.failure(AuthError.requiresRecentLogin)]
        let viewModel = makeViewModel(user: noNumber)

        await viewModel.deleteAccount()?.value

        #expect(viewModel.errorMessage == AuthError.requiresRecentLogin.errorDescription)
        #expect(!viewModel.isReverifying)
        #expect(auth.sentNumbers.isEmpty)
    }

    @Test("A failed re-verification code request shows the message")
    func reverifySendFailure() async {
        auth.deleteReplies = [.failure(AuthError.requiresRecentLogin)]
        auth.sendReplies = [.failure(AuthError.tooManyRequests)]
        let viewModel = makeViewModel()

        await viewModel.deleteAccount()?.value

        #expect(viewModel.errorMessage == AuthError.tooManyRequests.errorDescription)
        #expect(!viewModel.isReverifying)
        #expect(!viewModel.isWorking)
    }

    @Test("A second confirmation while one is running is ignored")
    func doubleConfirm() async throws {
        auth.deleteReplies = [.failure(AuthError.requiresRecentLogin), .success(())]
        let viewModel = makeViewModel()
        await viewModel.deleteAccount()?.value
        let gate = AsyncGate()
        auth.gate = gate

        let first = try #require(viewModel.updateCode("123456"))
        await gate.waitForArrival()
        #expect(viewModel.confirmReverification() == nil)
        #expect(viewModel.updateCode("654321") == nil)
        gate.open()
        await first.value

        let reauthentications = auth.calls.filter { if case .reauthenticate = $0 { true } else { false } }
        #expect(reauthentications == [.reauthenticate(verificationID: "verification-1", code: "123456")])
    }

    @Test("A new code can be requested only after the cooldown")
    func reverifyResend() async throws {
        auth.deleteReplies = [.failure(AuthError.requiresRecentLogin), .success(())]
        auth.sendReplies = [.success("verification-1"), .success("verification-2")]
        let viewModel = makeViewModel()
        await viewModel.deleteAccount()?.value
        #expect(viewModel.resendCooldownRemaining(at: clock.date) == 60)
        #expect(viewModel.resendCode() == nil)

        clock.advance(by: 45)
        #expect(viewModel.resendCooldownRemaining(at: clock.date) == 15)
        #expect(!viewModel.canResendCode(at: clock.date))
        clock.advance(by: 15)
        #expect(viewModel.canResendCode(at: clock.date))
        let task = try #require(viewModel.resendCode())
        await task.value

        #expect(auth.sentNumbers == [Fixture.phoneNumber, Fixture.phoneNumber])
        #expect(viewModel.resendCooldownRemaining(at: clock.date) == 60)

        await viewModel.updateCode("123456")?.value
        #expect(auth.calls.contains(.reauthenticate(verificationID: "verification-2", code: "123456")))
        #expect(auth.currentUser == nil)
    }

    @Test("Resending is not offered before a re-verification started")
    func resendWithoutReverification() {
        let viewModel = makeViewModel()

        #expect(!viewModel.canResendCode(at: clock.date))
        #expect(viewModel.resendCode() == nil)
    }

    @Test("Cancelling the re-verification goes back to the account and forgets the code")
    func cancelReverification() async {
        auth.deleteReplies = [.failure(AuthError.requiresRecentLogin)]
        let viewModel = makeViewModel()
        await viewModel.deleteAccount()?.value
        viewModel.updateCode("123")

        viewModel.cancelReverification()

        #expect(!viewModel.isReverifying)
        #expect(viewModel.codeText.isEmpty)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.resendAvailableAt == nil)
        #expect(viewModel.updateCode("123456") == nil, "The old verification id is gone")
        #expect(auth.count(of: .reauthenticate(verificationID: "verification-1", code: "123456")) == 0)
    }

    // MARK: - Helpers

    private func makeViewModel(user: AuthUser = Fixture.user) -> AccountViewModel {
        AccountViewModel(user: user, auth: auth, now: clock.now)
    }
}

import Foundation
import Testing
@testable import ViFi

@Suite("LoginViewModel", .timeLimit(.minutes(1)))
struct LoginViewModelTests {
    private let auth = StubAuthService()
    private let clock = TestClock()

    // MARK: - Number input

    @Test("A new view model asks for the number and cannot send anything yet")
    func initialState() {
        let viewModel = makeViewModel()

        #expect(viewModel.step == .phone)
        #expect(viewModel.phoneText.isEmpty)
        #expect(viewModel.codeText.isEmpty)
        #expect(viewModel.phoneNumber == nil)
        #expect(!viewModel.canSendCode)
        #expect(!viewModel.canVerify)
        #expect(!viewModel.isWorking)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.resendAvailableAt == nil)
    }

    @Test("The number is formatted as it is typed or pasted", arguments: [
        ("5", "5"),
        ("5321", "532 1"),
        ("05321234567", "532 123 45 67"),
        ("+90 532 123 45 67", "532 123 45 67"),
        ("+905321234567", "532 123 45 67"),
        ("0532-123-45-67", "532 123 45 67"),
        ("53212345678999", "532 123 45 67"),
    ])
    func phoneTextIsFormatted(input: String, expected: String) {
        let viewModel = makeViewModel()

        viewModel.updatePhoneText(input)

        #expect(viewModel.phoneText == expected)
    }

    @Test("Code can be sent only for a complete mobile number")
    func canSendCodeNeedsValidNumber() {
        let viewModel = makeViewModel()

        viewModel.updatePhoneText("532 123 45 6")
        #expect(!viewModel.canSendCode)
        #expect(viewModel.phoneNumber == nil)

        viewModel.updatePhoneText("532 123 45 67")
        #expect(viewModel.canSendCode)
        #expect(viewModel.phoneNumber?.e164 == Fixture.phoneNumber)

        viewModel.updatePhoneText("432 123 45 67")
        #expect(!viewModel.canSendCode, "A number not starting with 5 is not a mobile number")
    }

    @Test("Sending without a valid number does nothing")
    func sendCodeWithInvalidNumber() {
        let viewModel = makeViewModel()
        viewModel.updatePhoneText("532 123")

        #expect(viewModel.sendCode() == nil)

        #expect(auth.calls.isEmpty)
        #expect(!viewModel.isWorking)
    }

    @Test("Typing a number clears the previous error")
    func typingClearsError() async {
        auth.sendReplies = [.failure(AuthError.offline)]
        let viewModel = makeViewModel()
        viewModel.updatePhoneText("5321234567")
        await viewModel.sendCode()?.value
        #expect(viewModel.errorMessage != nil)

        viewModel.updatePhoneText("532 123 45 6")

        #expect(viewModel.errorMessage == nil)
    }

    // MARK: - Sending the code

    @Test("A sent code moves on to the code step and starts the resend cooldown")
    func sendCodeSuccess() async throws {
        let viewModel = makeViewModel()
        viewModel.updatePhoneText("0532 123 45 67")

        let task = viewModel.sendCode()
        #expect(viewModel.isWorking)
        await task?.value

        #expect(auth.sentNumbers == [Fixture.phoneNumber])
        #expect(viewModel.step == .code(try #require(PhoneNumber(nationalNumber: "5321234567"))))
        #expect(!viewModel.isWorking)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.codeText.isEmpty)
        #expect(viewModel.resendAvailableAt == clock.date.addingTimeInterval(LoginViewModel.resendCooldown))
    }

    @Test("A failed send stays on the number step and shows the message", arguments: [
        AuthError.invalidPhoneNumber,
        .tooManyRequests,
        .offline,
        .verificationCancelled,
        .appVerificationFailed,
        .unknown(message: "Bir sorun oluştu."),
    ])
    func sendCodeFailure(_ error: AuthError) async {
        auth.sendReplies = [.failure(error)]
        let viewModel = makeViewModel()
        viewModel.updatePhoneText("5321234567")

        await viewModel.sendCode()?.value

        #expect(viewModel.step == .phone)
        #expect(viewModel.errorMessage == error.errorDescription)
        #expect(!viewModel.isWorking)
        #expect(viewModel.canSendCode, "The user can try again")
        #expect(viewModel.resendAvailableAt == nil)
    }

    @Test("A cancelled send shows no error")
    func sendCodeCancelled() async {
        auth.sendReplies = [.failure(CancellationError())]
        let viewModel = makeViewModel()
        viewModel.updatePhoneText("5321234567")

        await viewModel.sendCode()?.value

        #expect(viewModel.errorMessage == nil)
        #expect(!viewModel.isWorking)
        #expect(viewModel.step == .phone)
    }

    @Test("A second tap while the code is being sent is ignored")
    func doubleTapOnSend() async throws {
        let gate = AsyncGate()
        auth.gate = gate
        let viewModel = makeViewModel()
        viewModel.updatePhoneText("5321234567")

        let first = try #require(viewModel.sendCode())
        await gate.waitForArrival()
        #expect(viewModel.isWorking)
        #expect(!viewModel.canSendCode)
        #expect(viewModel.sendCode() == nil)
        gate.open()
        await first.value

        #expect(auth.sentNumbers == [Fixture.phoneNumber])
        #expect(viewModel.step != .phone)
    }

    @Test("The number cannot be edited while the code is being sent")
    func numberLockedWhileSending() async throws {
        let gate = AsyncGate()
        auth.gate = gate
        let viewModel = makeViewModel()
        viewModel.updatePhoneText("5321234567")
        let task = try #require(viewModel.sendCode())
        await gate.waitForArrival()

        viewModel.updatePhoneText("5559999999")
        #expect(viewModel.phoneText == "532 123 45 67")

        gate.open()
        await task.value
    }

    @Test("A result that arrives after the screen is gone is dropped")
    func resultAfterViewModelIsGone() async throws {
        let gate = AsyncGate()
        auth.gate = gate
        var viewModel: LoginViewModel? = makeViewModel()
        viewModel?.updatePhoneText("5321234567")
        let task = try #require(viewModel?.sendCode())
        await gate.waitForArrival()
        weak let released = viewModel

        viewModel = nil
        #expect(released == nil, "An in-flight request must not keep the screen's model alive")
        gate.open()
        await task.value

        #expect(auth.sentNumbers == [Fixture.phoneNumber])
    }

    // MARK: - Verifying

    @Test("Verifying signs in with the verification id and the entered code")
    func verifySuccess() async throws {
        let viewModel = await makeCodeStep()
        viewModel.updateCode("12345")

        let task = try #require(viewModel.updateCode("123456"))
        await task.value

        #expect(auth.calls.last == .signIn(verificationID: "verification-1", code: "123456"))
        #expect(auth.currentUser == Fixture.user)
        #expect(viewModel.errorMessage == nil)
        // The session gate replaces the screen, so the model stays busy rather than flashing the form again.
        #expect(viewModel.isWorking)
    }

    @Test("The verify button signs in once all six digits are there")
    func verifyButton() async throws {
        let viewModel = await makeCodeStep()
        viewModel.updateCode("12345")
        #expect(!viewModel.canVerify)
        #expect(viewModel.verifyCode() == nil)
        #expect(auth.count(of: .signIn(verificationID: "verification-1", code: "12345")) == 0)

        viewModel.updateCode("1234")
        #expect(viewModel.codeText == "1234")
        #expect(!viewModel.canVerify)
    }

    @Test("The sixth digit submits the code by itself, however it arrives", arguments: [
        "123456",
        "123 456",
        "12-34-56",
        "1234567",
        "a1b2c3d4e5f6",
    ])
    func autoSubmit(input: String) async throws {
        let viewModel = await makeCodeStep()

        let task = try #require(viewModel.updateCode(input))
        await task.value

        #expect(viewModel.codeText == "123456")
        #expect(auth.calls.last == .signIn(verificationID: "verification-1", code: "123456"))
    }

    @Test("Fewer than six digits are kept but not submitted", arguments: ["1", "12", "12345"])
    func shortCodeIsNotSubmitted(input: String) async {
        let viewModel = await makeCodeStep()

        #expect(viewModel.updateCode(input) == nil)

        #expect(viewModel.codeText == input)
        #expect(auth.calls.count == 1, "Only the send call so far")
    }

    @Test("Letters and symbols are dropped from the code")
    func codeIsDigitsOnly() async {
        let viewModel = await makeCodeStep()

        viewModel.updateCode("a-1 b2")

        #expect(viewModel.codeText == "12")
    }

    @Test("Clearing the code field does not submit anything")
    func emptyCode() async {
        let viewModel = await makeCodeStep()
        viewModel.updateCode("123")

        #expect(viewModel.updateCode("") == nil)

        #expect(viewModel.codeText.isEmpty)
    }

    @Test("A wrong code shows the message, clears the field and allows another try")
    func invalidCode() async throws {
        auth.signInReplies = [.failure(AuthError.invalidCode), .success(Fixture.user)]
        let viewModel = await makeCodeStep()

        await viewModel.updateCode("000000")?.value

        #expect(viewModel.errorMessage == AuthError.invalidCode.errorDescription)
        #expect(viewModel.codeText.isEmpty)
        #expect(!viewModel.isWorking)
        #expect(viewModel.step != .phone)
        #expect(auth.currentUser == nil)

        let retry = try #require(viewModel.updateCode("123456"))
        #expect(viewModel.errorMessage == nil, "Typing again clears the message")
        await retry.value

        #expect(auth.currentUser == Fixture.user)
        #expect(auth.count(of: .signIn(verificationID: "verification-1", code: "123456")) == 1)
    }

    @Test("An expired code asks for a new one, which may be requested at once")
    func expiredCode() async {
        auth.signInReplies = [.failure(AuthError.codeExpired)]
        let viewModel = await makeCodeStep()
        #expect(!viewModel.canResendCode(at: clock.date))

        await viewModel.updateCode("123456")?.value

        #expect(viewModel.errorMessage == AuthError.codeExpired.errorDescription)
        #expect(viewModel.codeText.isEmpty)
        #expect(viewModel.resendAvailableAt == nil)
        #expect(viewModel.canResendCode(at: clock.date))
    }

    @Test("Other sign-in errors keep the code so the user can retry", arguments: [
        AuthError.tooManyRequests,
        .offline,
        .appVerificationFailed,
    ])
    func otherVerifyFailure(_ error: AuthError) async {
        auth.signInReplies = [.failure(error)]
        let viewModel = await makeCodeStep()

        await viewModel.updateCode("123456")?.value

        #expect(viewModel.errorMessage == error.errorDescription)
        #expect(viewModel.codeText == "123456")
        #expect(!viewModel.isWorking)
        #expect(viewModel.canVerify)
    }

    @Test("A cancelled sign-in shows no error")
    func verifyCancelled() async {
        auth.signInReplies = [.failure(CancellationError())]
        let viewModel = await makeCodeStep()

        await viewModel.updateCode("123456")?.value

        #expect(viewModel.errorMessage == nil)
        #expect(!viewModel.isWorking)
    }

    @Test("A second submit while signing in is ignored")
    func doubleTapOnVerify() async throws {
        let viewModel = await makeCodeStep()
        let gate = AsyncGate()
        auth.gate = gate
        let first = try #require(viewModel.updateCode("123456"))
        await gate.waitForArrival()

        #expect(viewModel.isWorking)
        #expect(!viewModel.canVerify)
        #expect(viewModel.verifyCode() == nil)
        #expect(viewModel.updateCode("654321") == nil)
        #expect(viewModel.codeText == "123456", "The code cannot change while it is being checked")
        #expect(viewModel.resendCode() == nil)
        gate.open()
        await first.value

        let signIns = auth.calls.filter { if case .signIn = $0 { true } else { false } }
        #expect(signIns == [.signIn(verificationID: "verification-1", code: "123456")])
    }

    @Test("A code typed before any code was sent is not submitted")
    func codeWithoutVerificationID() {
        let viewModel = makeViewModel()

        #expect(viewModel.updateCode("123456") == nil)

        #expect(auth.calls.isEmpty)
    }

    // MARK: - Helpers

    private func makeViewModel() -> LoginViewModel {
        LoginViewModel(auth: auth, now: clock.now)
    }

    /// A view model that has sent a code to `+90 532 123 45 67` (verification id `verification-1`).
    private func makeCodeStep() async -> LoginViewModel {
        let viewModel = makeViewModel()
        viewModel.updatePhoneText("5321234567")
        await viewModel.sendCode()?.value
        return viewModel
    }
}

/// Requesting another code and changing the number, on the code step.
@Suite("LoginViewModel code step", .timeLimit(.minutes(1)))
struct LoginViewModelCodeStepTests {
    private let auth = StubAuthService()
    private let clock = TestClock()

    // MARK: - Resending

    @Test("A new code can be requested only after the cooldown")
    func resendCooldown() async throws {
        auth.sendReplies = [.success("verification-1"), .success("verification-2")]
        let viewModel = await makeCodeStep()
        let cooldown = Int(LoginViewModel.resendCooldown)
        #expect(cooldown == 60)

        #expect(viewModel.resendCooldownRemaining(at: clock.date) == 60)
        #expect(!viewModel.canResendCode(at: clock.date))
        #expect(viewModel.resendCode() == nil)

        clock.advance(by: 0.5)
        #expect(viewModel.resendCooldownRemaining(at: clock.date) == 60, "Partial seconds round up")
        clock.advance(by: 29.5)
        #expect(viewModel.resendCooldownRemaining(at: clock.date) == 30)
        #expect(!viewModel.canResendCode(at: clock.date))
        #expect(viewModel.resendCode() == nil)
        #expect(auth.sentNumbers.count == 1)

        clock.advance(by: 29)
        #expect(viewModel.resendCooldownRemaining(at: clock.date) == 1)
        #expect(!viewModel.canResendCode(at: clock.date))

        clock.advance(by: 1)
        #expect(viewModel.resendCooldownRemaining(at: clock.date) == 0)
        #expect(viewModel.canResendCode(at: clock.date))

        let task = try #require(viewModel.resendCode())
        await task.value

        #expect(auth.sentNumbers == [Fixture.phoneNumber, Fixture.phoneNumber])
        #expect(viewModel.resendCooldownRemaining(at: clock.date) == 60, "Every code starts a new cooldown")
        #expect(!viewModel.canResendCode(at: clock.date))
    }

    @Test("The cooldown never goes below zero")
    func cooldownStaysAtZero() async {
        let viewModel = await makeCodeStep()

        clock.advance(by: 3600)

        #expect(viewModel.resendCooldownRemaining(at: clock.date) == 0)
    }

    @Test("Resending is not offered on the number step")
    func resendOnNumberStep() {
        let viewModel = makeViewModel()

        #expect(!viewModel.canResendCode(at: clock.date))
        #expect(viewModel.resendCode() == nil)
        #expect(viewModel.resendCooldownRemaining(at: clock.date) == 0)
    }

    @Test("A resent code replaces the verification id used to sign in")
    func resentCodeUsesNewVerificationID() async throws {
        auth.sendReplies = [.success("verification-1"), .success("verification-2")]
        let viewModel = await makeCodeStep()
        clock.advance(by: LoginViewModel.resendCooldown)
        viewModel.updateCode("111")
        await viewModel.resendCode()?.value
        #expect(viewModel.codeText.isEmpty, "A new code starts with an empty field")

        let task = try #require(viewModel.updateCode("123456"))
        await task.value

        #expect(auth.calls.last == .signIn(verificationID: "verification-2", code: "123456"))
    }

    @Test("A failed resend shows the message and leaves the code step")
    func resendFailure() async {
        auth.sendReplies = [.success("verification-1"), .failure(AuthError.tooManyRequests)]
        let viewModel = await makeCodeStep()
        clock.advance(by: LoginViewModel.resendCooldown)

        await viewModel.resendCode()?.value

        #expect(viewModel.errorMessage == AuthError.tooManyRequests.errorDescription)
        #expect(viewModel.step != .phone)
        #expect(!viewModel.isWorking)
        #expect(!viewModel.canVerify)
    }

    // MARK: - Changing the number

    @Test("Changing the number returns to the number step and forgets the code")
    func changeNumber() async {
        let viewModel = await makeCodeStep()
        viewModel.updateCode("123")

        viewModel.changeNumber()

        #expect(viewModel.step == .phone)
        #expect(viewModel.phoneText == "532 123 45 67", "The number stays for editing")
        #expect(viewModel.codeText.isEmpty)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.resendAvailableAt == nil)
        #expect(viewModel.canSendCode)
        #expect(viewModel.updateCode("123456") == nil, "The old verification id is gone")
        #expect(!viewModel.canVerify)
    }

    @Test("Another number gets its own code")
    func sendToAnotherNumber() async throws {
        auth.sendReplies = [.success("verification-1"), .success("verification-2")]
        let viewModel = await makeCodeStep()
        viewModel.changeNumber()
        viewModel.updatePhoneText("555 444 33 22")

        await viewModel.sendCode()?.value

        #expect(auth.sentNumbers == [Fixture.phoneNumber, "+905554443322"])
        let number = try #require(PhoneNumber(input: "5554443322"))
        #expect(viewModel.step == .code(number))
        await viewModel.updateCode("123456")?.value
        #expect(auth.calls.last == .signIn(verificationID: "verification-2", code: "123456"))
    }

    @Test("Re-entering the same number within the cooldown shows the sent code again instead of a new SMS")
    func sameNumberKeepsCooldown() async throws {
        auth.sendReplies = [.success("verification-1"), .success("verification-2")]
        auth.signInReplies = [.failure(AuthError.invalidCode)]
        let viewModel = await makeCodeStep()
        clock.advance(by: 20)
        viewModel.changeNumber()

        #expect(viewModel.sendCode() == nil)

        #expect(auth.sentNumbers == [Fixture.phoneNumber])
        let number = try #require(PhoneNumber(input: "5321234567"))
        #expect(viewModel.step == .code(number))
        #expect(viewModel.resendCooldownRemaining(at: clock.date) == 40)
        await viewModel.updateCode("123456")?.value
        #expect(auth.calls.last == .signIn(verificationID: "verification-1", code: "123456"))

        viewModel.changeNumber()
        clock.advance(by: 40)
        await viewModel.sendCode()?.value
        #expect(auth.sentNumbers == [Fixture.phoneNumber, Fixture.phoneNumber], "A new code once the cooldown is over")
    }

    @Test("The number cannot be changed while a request is running")
    func changeNumberWhileWorking() async throws {
        let viewModel = await makeCodeStep()
        let gate = AsyncGate()
        auth.gate = gate
        let task = try #require(viewModel.updateCode("123456"))
        await gate.waitForArrival()

        viewModel.changeNumber()
        #expect(viewModel.step != .phone)

        gate.open()
        await task.value
    }

    // MARK: - Helpers

    /// A view model that has sent a code to `+90 532 123 45 67` (verification id `verification-1`).
    private func makeCodeStep() async -> LoginViewModel {
        let viewModel = LoginViewModel(auth: auth, now: clock.now)
        viewModel.updatePhoneText("5321234567")
        await viewModel.sendCode()?.value
        return viewModel
    }

    private func makeViewModel() -> LoginViewModel {
        LoginViewModel(auth: auth, now: clock.now)
    }
}

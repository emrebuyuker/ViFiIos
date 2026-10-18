import Foundation
import Testing
@testable import ViFi

@Suite("Login diagnostics")
struct LoginDiagnosticsTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Throttle

    @Test("The first report of a signature is sent")
    func throttleAllowsFirst() {
        var throttle = LoginDiagnosticThrottle(window: 60)
        let first = throttle.shouldSend("a", at: base)
        #expect(first)
    }

    @Test("An identical report inside the window is suppressed, then allowed again after it")
    func throttleSuppressesDuplicates() {
        var throttle = LoginDiagnosticThrottle(window: 60)
        let first = throttle.shouldSend("a", at: base)
        let duplicateEarly = throttle.shouldSend("a", at: base.addingTimeInterval(1))
        let duplicateLate = throttle.shouldSend("a", at: base.addingTimeInterval(59))
        let afterWindow = throttle.shouldSend("a", at: base.addingTimeInterval(60))
        #expect(first)
        #expect(!duplicateEarly)
        #expect(!duplicateLate)
        #expect(afterWindow)
    }

    @Test("A different signature is always sent, even inside the window")
    func throttleAllowsDifferentSignatures() {
        var throttle = LoginDiagnosticThrottle(window: 60)
        let first = throttle.shouldSend("a", at: base)
        let other = throttle.shouldSend("b", at: base.addingTimeInterval(1))
        #expect(first)
        #expect(other)
    }

    // MARK: - Support context

    @Test("The support context carries the number, stage and the backend code for Error 39")
    func supportContextForError39() {
        let info = LoginFailureInfo(
            reason: "sms_temporarily_unavailable",
            backendCode: 39,
            stage: .sendCode,
            phoneNumber: "+905321234567",
            occurredAt: base
        )
        let context = info.supportContext
        #expect(context.contains("+905321234567"))
        #expect(context.contains("Kod gönderme"))
        #expect(context.contains("Error code: 39"))
    }

    // MARK: - View model reporting

    @Test("A failed code request reports a diagnostic and a login_failed event with the send_code stage")
    func reportsSendCodeFailure() async {
        let auth = StubAuthService()
        auth.sendReplies = [.failure(AuthError.smsTemporarilyUnavailable)]
        let analytics = AnalyticsSpy()
        let diagnostics = SpyLoginDiagnosticsReporter()
        let clock = TestClock()
        let viewModel = LoginViewModel(auth: auth, analytics: analytics, diagnostics: diagnostics, now: clock.now)

        viewModel.updatePhoneText("5321234567")
        await viewModel.sendCode()?.value

        #expect(diagnostics.reports.count == 1)
        let report = diagnostics.reports.first
        #expect(report?.reason == "sms_temporarily_unavailable")
        #expect(report?.backendCode == 39)
        #expect(report?.stage == .sendCode)
        #expect(report?.phoneNumber == "+905321234567")
        #expect(analytics.events.contains(.loginFailed(reason: "sms_temporarily_unavailable", step: "send_code")))
        #expect(viewModel.supportContext?.contains("+905321234567") == true)
    }

    @Test("A failed code verification reports a diagnostic with the verify stage and no backend code")
    func reportsVerifyFailure() async {
        let auth = StubAuthService()
        auth.sendReplies = [.success("verification-1")]
        auth.signInReplies = [.failure(AuthError.invalidCode)]
        let analytics = AnalyticsSpy()
        let diagnostics = SpyLoginDiagnosticsReporter()
        let clock = TestClock()
        let viewModel = LoginViewModel(auth: auth, analytics: analytics, diagnostics: diagnostics, now: clock.now)

        viewModel.updatePhoneText("5321234567")
        await viewModel.sendCode()?.value
        await viewModel.updateCode("111111")?.value

        let verifyReport = diagnostics.reports.last
        #expect(verifyReport?.stage == .verify)
        #expect(verifyReport?.reason == "invalid_code")
        #expect(verifyReport?.backendCode == nil)
        #expect(verifyReport?.phoneNumber == "+905321234567")
        #expect(analytics.events.contains(.loginFailed(reason: "invalid_code", step: "verify")))
    }

    @Test("With no failure yet, the support context still carries the typed number")
    func supportContextBeforeAnyFailure() {
        let viewModel = LoginViewModel(auth: StubAuthService(), analytics: AnalyticsSpy())
        #expect(viewModel.supportContext == nil)
        viewModel.updatePhoneText("5321234567")
        #expect(viewModel.supportContext?.contains("+905321234567") == true)
    }
}

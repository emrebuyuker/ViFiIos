import Foundation

/// Which stage of sign-in failed. Stable, language-independent raw values, shared by analytics and the
/// diagnostics sink.
nonisolated enum LoginFailureStage: String, Sendable, Equatable {
    /// Requesting the SMS code (`sendVerificationCode`) — where Error 39 and App Check rejections surface.
    case sendCode = "send_code"
    /// Verifying the entered code (`signIn`).
    case verify

    var turkishLabel: String {
        switch self {
        case .sendCode: "Kod gönderme"
        case .verify: "Kod doğrulama"
        }
    }
}

/// A structured record of a failed sign-in attempt, assembled by `LoginViewModel` with no Firebase types, so it
/// can be built and tested in mock mode. The live reporter enriches it (App Check status, device, version)
/// before sending it to the diagnostics sink.
nonisolated struct LoginFailureInfo: Sendable, Equatable {
    /// The stable analytics reason (`AuthError.analyticsReason`), e.g. `sms_temporarily_unavailable`.
    let reason: String
    /// The backend code behind the failure when known (39 for the SMS anti-abuse rejection), else `nil`.
    let backendCode: Int?
    let stage: LoginFailureStage
    /// The attempted number in E.164 (`+90…`), or `nil` when it is not known.
    let phoneNumber: String?
    let occurredAt: Date

    /// A short, human-readable Turkish summary prefilled into the support e-mail (Faz 1). It carries the full
    /// number because the user sends the mail themselves; nothing is hashed here.
    var supportContext: String {
        var lines = ["Giriş sorunu bildirimi"]
        if let phoneNumber { lines.append("Numara: \(phoneNumber)") }
        lines.append("Aşama: \(stage.turkishLabel)")
        lines.append("Sebep: \(reason)\(backendCode.map { " (Error code: \($0))" } ?? "")")
        return lines.joined(separator: "\n")
    }
}

/// Reports failed sign-in attempts to the diagnostics sink. The live implementation calls a Cloud Function; the
/// no-op is used in mock mode and as the default, so nothing is reported unless the app is wired to Firebase.
protocol LoginDiagnosticsReporting: AnyObject {
    func report(_ info: LoginFailureInfo)
}

/// Drops every report. Used in mock/preview/tests and as the default dependency.
final class NoopLoginDiagnosticsReporter: LoginDiagnosticsReporting {
    init() {}
    func report(_ info: LoginFailureInfo) {}
}

/// Decides whether a diagnostic should actually be sent, so repeated identical failures — e.g. the user tapping
/// "Kod Gönder" again and again against the same backend rejection — do not spam the Cloud Function. A report is
/// sent when its signature differs from the last sent one, or when `window` has elapsed since the last send of
/// the same signature. Pure and synchronous, so it is unit-tested directly.
struct LoginDiagnosticThrottle {
    /// How long an identical report stays suppressed after one is sent.
    let window: TimeInterval
    private var lastSignature: String?
    private var lastSentAt: Date?

    init(window: TimeInterval = 60) {
        self.window = window
    }

    /// Records and allows the report when it should be sent; returns `false` (changing nothing) when it is a
    /// duplicate inside the window.
    mutating func shouldSend(_ signature: String, at date: Date) -> Bool {
        if lastSignature == signature, let lastSentAt, date.timeIntervalSince(lastSentAt) < window {
            return false
        }
        lastSignature = signature
        lastSentAt = date
        return true
    }
}

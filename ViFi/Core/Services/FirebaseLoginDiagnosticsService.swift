@preconcurrency import FirebaseAppCheck
@preconcurrency import FirebaseFunctions
import Foundation
import os
import UIKit

/// Reports failed sign-in attempts to the `recordLoginDiagnostic` Cloud Function so support can later look up why
/// a specific number could not sign in. Fire-and-forget: it never blocks or fails the login flow, and a lost
/// report is acceptable.
///
/// App Check is deliberately NOT enforced on the function (a login that fails *because* App Check cannot be minted
/// must still be recorded); instead this probes the device's App Check status and sends it as data, and the
/// function records the server-side verification result too.
///
/// A signature-based throttle drops repeated identical reports (the user retrying the same number against the same
/// backend rejection) so the function is not spammed.
final class FirebaseLoginDiagnosticsService: LoginDiagnosticsReporting {
    private static let region = "europe-west1"
    private static let name = "recordLoginDiagnostic"

    private let functions: Functions
    private let appCheck: AppCheck?
    private var throttle = LoginDiagnosticThrottle()

    init(functions: Functions = Functions.functions(region: region), appCheck: AppCheck? = AppCheck.appCheck()) {
        self.functions = functions
        self.appCheck = appCheck
    }

    func report(_ info: LoginFailureInfo) {
        let signature = "\(info.phoneNumber ?? "")|\(info.reason)|\(info.stage.rawValue)"
        guard throttle.shouldSend(signature, at: Date()) else {
            Logger.app.debug("Login diagnostic suppressed (duplicate): \(info.reason, privacy: .public)")
            return
        }
        let functions = functions
        let appCheck = appCheck
        Task {
            // Build the payload inline (only value types) so region isolation can send it to the callable; a
            // `[String: Any]` returned across an async boundary would trip Swift 6 concurrency.
            let appCheckStatus = await Self.appCheckStatus(appCheck)
            var payload: [String: Any] = [
                "reason": info.reason,
                "step": info.stage.rawValue,
                "phoneNumber": info.phoneNumber ?? "",
                "appCheckStatus": appCheckStatus,
                "appVersion": "\(Bundle.main.shortVersionString) (\(Bundle.main.buildVersionString))",
                "osVersion": UIDevice.current.systemVersion,
                "deviceModel": Self.deviceModel,
                "occurredAt": ISO8601DateFormatter().string(from: info.occurredAt),
            ]
            if let backendCode = info.backendCode { payload["backendCode"] = backendCode }
            do {
                _ = try await functions.httpsCallable(Self.name).call(payload)
            } catch {
                // Diagnostics must never surface to the user; losing one record is acceptable.
                Logger.app.error("Login diagnostic report failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Probes whether the device can mint an App Check token right now. "error" is itself a strong signal that
    /// App Check is the reason sign-in failed.
    private static func appCheckStatus(_ appCheck: AppCheck?) async -> String {
        guard let appCheck else { return "unavailable" }
        do {
            _ = try await appCheck.token(forcingRefresh: false)
            return "valid"
        } catch {
            return "error"
        }
    }

    /// The hardware identifier (e.g. "iPhone16,2"), which affects App Attest availability; falls back to the
    /// generic model name.
    private static var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = Mirror(reflecting: systemInfo.machine).children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }
}

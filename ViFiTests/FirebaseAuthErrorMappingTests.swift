import Foundation
import Testing
@testable import ViFi

/// `FirebaseAuthService.authError(from:)` turns raw Firebase `NSError`s into the `AuthError`s the UI shows.
/// The SMS anti-abuse rejection ("Error code: 39") is the interesting case: Firebase hides it inside a generic
/// `internalError`, so these tests pin the exact nested shape we rely on to recognise it.
@Suite("FirebaseAuthService error mapping")
struct FirebaseAuthErrorMappingTests {
    /// The real production error, reproduced from a device log: an `internalError` whose underlying
    /// `FIRAuthInternalErrorDomain` error carries the deserialized backend body with "Error code: 39".
    @Test("The anti-abuse rejection (Error code: 39) maps to smsTemporarilyUnavailable")
    func mapsError39ToSMSTemporarilyUnavailable() {
        let error = internalError(deserializedResponse: [
            "code": 503,
            "message": "Error code: 39",
            "errors": [
                ["domain": "global", "message": "Error code: 39", "reason": "backendError"],
            ],
        ])

        #expect(FirebaseAuthService.authError(from: error) == .smsTemporarilyUnavailable)
    }

    @Test("A 39 code reported only inside the nested errors array is still recognised")
    func mapsError39FromNestedErrorsArray() {
        let error = internalError(deserializedResponse: [
            "code": 503,
            "message": "An unexpected backend problem occurred",
            "errors": [
                ["domain": "global", "message": "Error code: 39", "reason": "backendError"],
            ],
        ])

        #expect(FirebaseAuthService.authError(from: error) == .smsTemporarilyUnavailable)
    }

    @Test("A different backend code is not mistaken for the SMS rejection")
    func otherBackendCodesFallBackToGeneric() {
        let error = internalError(deserializedResponse: [
            "code": 503,
            "message": "Error code: 17",
            "errors": [["message": "Error code: 17"]],
        ])

        #expect(FirebaseAuthService.authError(from: error) == .unknown(message: FirebaseAuthService.genericErrorMessage))
    }

    @Test("A code 390 does not match the 39 rejection")
    func adjacentNumbersDoNotMatch() {
        let error = internalError(deserializedResponse: ["message": "Error code: 390"])

        #expect(!FirebaseAuthService.isSMSTemporarilyUnavailable(error))
    }

    @Test("A plain internalError without a backend body stays generic")
    func genericInternalErrorStaysGeneric() {
        let error = NSError(
            domain: "FIRAuthErrorDomain",
            code: 17999,
            userInfo: [NSLocalizedDescriptionKey: "An internal error has occurred."]
        )

        #expect(FirebaseAuthService.authError(from: error) == .unknown(message: FirebaseAuthService.genericErrorMessage))
    }

    @Test("A network error maps to offline regardless of the anti-abuse check")
    func networkErrorStaysOffline() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)

        #expect(FirebaseAuthService.authError(from: error) == .offline)
    }

    // MARK: - Helpers

    /// Builds the `FIRAuthErrorDomain` / `17999` envelope Firebase wraps backend failures in, mirroring the real
    /// `NSUnderlyingError` → `FIRAuthInternalErrorDomain` → `FIRAuthErrorUserInfoDeserializedResponseKey` chain.
    private func internalError(deserializedResponse: [String: Any]) -> NSError {
        let httpError = NSError(domain: "com.google.HTTPStatus", code: 503)
        let underlying = NSError(
            domain: "FIRAuthInternalErrorDomain",
            code: 3,
            userInfo: [
                "FIRAuthErrorUserInfoDeserializedResponseKey": deserializedResponse,
                NSUnderlyingErrorKey: httpError,
            ]
        )
        return NSError(
            domain: "FIRAuthErrorDomain",
            code: 17999,
            userInfo: [
                NSUnderlyingErrorKey: underlying,
                "FIRAuthErrorUserInfoNameKey": "ERROR_INTERNAL_ERROR",
                NSLocalizedDescriptionKey: "An internal error has occurred, print and inspect the error details for more information.",
            ]
        )
    }
}

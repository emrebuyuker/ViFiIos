import FirebaseFirestore
import FirebaseFunctions
import Foundation
import Testing
@testable import ViFi

/// `FirebaseNotificationAdminService.adminError(from:)` turns Functions, Firestore and transport errors into the
/// `NotificationAdminError`s the composer shows.
@Suite("FirebaseNotificationAdminService error mapping")
struct FirebaseNotificationAdminServiceTests {
    private func functionsError(_ code: FunctionsErrorCode, message: String = "Sunucu mesajı") -> NSError {
        NSError(domain: FunctionsErrorDomain, code: code.rawValue, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func firestoreError(_ code: FirestoreErrorCode.Code) -> NSError {
        NSError(domain: FirestoreErrorDomain, code: code.rawValue)
    }

    @Test("Permission and sign-in failures mean the user is not an admin")
    func permission() {
        for code in [FunctionsErrorCode.permissionDenied, .unauthenticated] {
            #expect(FirebaseNotificationAdminService.adminError(from: functionsError(code)) == .permissionDenied)
        }
    }

    @Test("A refused draft carries the server's Turkish message")
    func invalidDraft() {
        let error = functionsError(.invalidArgument, message: "Başlık en fazla 80 karakter olabilir.")
        #expect(FirebaseNotificationAdminService.adminError(from: error) == .invalidDraft(message: "Başlık en fazla 80 karakter olabilir."))

        let precondition = functionsError(.failedPrecondition, message: "Görsel henüz desteklenmiyor.")
        #expect(FirebaseNotificationAdminService.adminError(from: precondition) == .invalidDraft(message: "Görsel henüz desteklenmiyor."))
    }

    @Test("A failed precondition on cancel means it already went out")
    func notCancelable() {
        let error = functionsError(.failedPrecondition)
        #expect(FirebaseNotificationAdminService.adminError(from: error, isCancellation: true) == .notCancelable)
        // Other errors on cancel keep their normal mapping.
        #expect(FirebaseNotificationAdminService.adminError(from: functionsError(.permissionDenied), isCancellation: true) == .permissionDenied)
    }

    @Test("Connectivity problems read as offline")
    func offline() {
        #expect(FirebaseNotificationAdminService.adminError(from: functionsError(.unavailable)) == .offline)
        #expect(FirebaseNotificationAdminService.adminError(from: functionsError(.deadlineExceeded)) == .offline)
        #expect(FirebaseNotificationAdminService.adminError(from: firestoreError(.unavailable)) == .offline)
        let transport = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        #expect(FirebaseNotificationAdminService.adminError(from: transport) == .offline)
    }

    @Test("Reading the history without the admin claim is a permission error")
    func firestorePermission() {
        #expect(FirebaseNotificationAdminService.adminError(from: firestoreError(.permissionDenied)) == .permissionDenied)
    }

    @Test("Anything else is unknown, with the underlying message")
    func unknown() {
        let internalError = functionsError(.internal, message: "Beklenmeyen")
        #expect(FirebaseNotificationAdminService.adminError(from: internalError) == .unknown(message: "Beklenmeyen"))
        #expect(FirebaseNotificationAdminService.adminError(from: firestoreError(.dataLoss)) != .offline)
    }
}

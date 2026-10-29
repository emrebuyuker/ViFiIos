import FirebaseFirestore
import Foundation
import Testing
@testable import ViFi

@Suite("FirebaseNotificationSettingsService")
struct FirebaseNotificationSettingsServiceTests {
    @Test("A boolean marketing field is the consent")
    func parsesConsent() {
        #expect(FirebaseNotificationSettingsService.parse(["marketing": true, "source": "prompt"])
            == NotificationConsent(marketing: true))
        #expect(FirebaseNotificationSettingsService.parse(["marketing": false])
            == NotificationConsent(marketing: false))
    }

    @Test("No document, or no boolean marketing field, is no answer")
    func parsesNoAnswer() {
        #expect(FirebaseNotificationSettingsService.parse(nil) == nil)
        #expect(FirebaseNotificationSettingsService.parse([:]) == nil)
        #expect(FirebaseNotificationSettingsService.parse(["marketing": "yes"]) == nil)
    }

    @Test("The written fields are exactly the ones the security rules accept")
    func fieldsMatchTheRules() throws {
        for (source, expected) in [(NotificationConsentSource.prompt, "prompt"), (.settings, "settings")] {
            let fields = FirebaseNotificationSettingsService.fields(marketing: true, source: source)

            #expect(Set(fields.keys) == ["marketing", "source", "version", "updatedAt"])
            #expect(fields["marketing"] as? Bool == true)
            #expect(fields["source"] as? String == expected)
            let version = try #require(fields["version"] as? Int)
            #expect((1...99).contains(version))
            // `updatedAt == request.time` in the rules: it must be the server timestamp, never a client date.
            #expect(fields["updatedAt"] is FieldValue)
        }
    }

    @Test("A no is written as marketing false")
    func writesNo() {
        let fields = FirebaseNotificationSettingsService.fields(marketing: false, source: .settings)
        #expect(fields["marketing"] as? Bool == false)
    }
}

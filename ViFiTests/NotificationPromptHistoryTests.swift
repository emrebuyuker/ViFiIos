import Foundation
import Testing
@testable import ViFi

@Suite("NotificationPromptHistory")
struct NotificationPromptHistoryTests {
    private static let day: TimeInterval = 24 * 60 * 60

    private let storage: TemporaryDefaults
    private let clock = TestClock()
    private let history: NotificationPromptHistory

    init() throws {
        storage = try TemporaryDefaults()
        history = NotificationPromptHistory(defaults: storage.defaults, now: clock.now)
    }

    @Test("A fresh device has offered nothing and has nothing to re-ask")
    func freshDevice() {
        #expect(!history.hasOfferedPriming)
        #expect(!history.hasOfferedConsent)
        #expect(!history.shouldReaskPermission())
        #expect(!history.shouldReaskConsent())
    }

    @Test("Offering is remembered across instances")
    func offeringPersists() {
        history.markPrimingOffered()
        history.markConsentOffered()

        let later = NotificationPromptHistory(defaults: storage.defaults, now: clock.now)
        #expect(later.hasOfferedPriming)
        #expect(later.hasOfferedConsent)
    }

    // MARK: - Permission re-ask

    @Test("The permission re-ask is due 30 days after the first no, not before")
    func permissionReaskTiming() {
        history.recordPermissionDeclined()

        clock.advance(by: 29 * Self.day + 23 * 3_600)
        #expect(!history.shouldReaskPermission())

        clock.advance(by: 3_600)
        #expect(history.shouldReaskPermission())

        clock.advance(by: 90 * Self.day)
        #expect(history.shouldReaskPermission(), "Once due it stays due until it is shown")
    }

    @Test("The permission re-ask is offered once")
    func permissionReaskOnce() {
        history.recordPermissionDeclined()
        clock.advance(by: 31 * Self.day)
        #expect(history.shouldReaskPermission())

        history.markPermissionReaskShown()
        #expect(!history.shouldReaskPermission())

        // Saying no to the re-ask does not arm another one.
        history.recordPermissionDeclined()
        clock.advance(by: 365 * Self.day)
        #expect(!history.shouldReaskPermission())
    }

    @Test("Only the first no starts the wait: a later one cannot postpone the re-ask")
    func firstNoWins() {
        history.recordPermissionDeclined()
        clock.advance(by: 20 * Self.day)
        history.recordPermissionDeclined()

        clock.advance(by: 10 * Self.day)
        #expect(history.shouldReaskPermission())
    }

    @Test("A re-ask is never due without a no")
    func noReaskWithoutNo() {
        history.markPrimingOffered()
        clock.advance(by: 400 * Self.day)
        #expect(!history.shouldReaskPermission())
    }

    // MARK: - Consent re-ask

    @Test("The consent re-ask follows the same rules, independent of the permission")
    func consentReask() {
        history.recordConsentDeclined()
        #expect(!history.shouldReaskConsent())
        #expect(!history.shouldReaskPermission())

        clock.advance(by: 30 * Self.day)
        #expect(history.shouldReaskConsent())
        #expect(!history.shouldReaskPermission())

        history.markConsentReaskShown()
        #expect(!history.shouldReaskConsent())
    }

    @Test("The reask delay is thirty days")
    func delayIsThirtyDays() {
        #expect(NotificationPromptHistory.reaskDelay == 30 * Self.day)
    }
}

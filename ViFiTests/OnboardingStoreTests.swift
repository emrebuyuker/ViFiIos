import Foundation
import Testing
@testable import ViFi

/// Each test gets its own `UserDefaults` suite, deleted afterwards.
@Suite("OnboardingStore")
final class OnboardingStoreTests {
    private let storage: TemporaryDefaults

    init() throws {
        storage = try TemporaryDefaults()
    }

    @Test("A fresh install presents the tour")
    func freshInstallPresentsTour() {
        #expect(OnboardingStore(defaults: storage.defaults).isPresenting)
    }

    @Test("Marking the tour seen hides it and persists across launches")
    func markSeenPersistsAcrossLaunches() {
        let store = OnboardingStore(defaults: storage.defaults)

        store.markSeen()

        #expect(!store.isPresenting)
        // A new store on the same defaults reads the persisted flag: the next launch does not show the tour.
        #expect(!OnboardingStore(defaults: storage.defaults).isPresenting)
    }

    @Test("A stored seen flag suppresses the tour")
    func storedSeenFlagSuppressesTour() {
        OnboardingStore.seed(seen: true, into: storage.defaults)

        #expect(!OnboardingStore(defaults: storage.defaults).isPresenting)
    }
}

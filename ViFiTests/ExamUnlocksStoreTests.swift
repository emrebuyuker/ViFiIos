import Foundation
import Testing
@testable import ViFi

/// A reader returning a fixed set (or throwing), for the store tests.
private final class FixedUnlocksReader: UnlocksReading {
    private let ids: Set<String>
    private let error: (any Error)?

    init(_ ids: Set<String> = [], error: (any Error)? = nil) {
        self.ids = ids
        self.error = error
    }

    func unlockedExamIds(uid: String) async throws -> Set<String> {
        if let error { throw error }
        return ids
    }
}

@MainActor
@Suite("ExamUnlocksStore")
struct ExamUnlocksStoreTests {
    @Test("Loading reads the user's unlocks")
    func loadsUnlocks() async {
        let store = ExamUnlocksStore(reader: FixedUnlocksReader(["a", "b"]))
        await store.load(uid: "user-1")
        #expect(store.unlockedIds == ["a", "b"])
        #expect(store.isUnlocked("a"))
        #expect(!store.isUnlocked("c"))
    }

    @Test("A failed load keeps the set empty")
    func failedLoadKeepsEmpty() async {
        let store = ExamUnlocksStore(reader: FixedUnlocksReader(error: ExamUnlockError.offline))
        await store.load(uid: "user-1")
        #expect(store.unlockedIds.isEmpty)
    }

    @Test("Marking an exam unlocked adds it")
    func markUnlockedAdds() {
        let store = ExamUnlocksStore(reader: FixedUnlocksReader())
        store.markUnlocked("x")
        #expect(store.isUnlocked("x"))
    }

    @Test("Reset clears the set")
    func resetClears() async {
        let store = ExamUnlocksStore(reader: FixedUnlocksReader(["a"]))
        await store.load(uid: "user-1")
        store.reset()
        #expect(store.unlockedIds.isEmpty)
    }
}

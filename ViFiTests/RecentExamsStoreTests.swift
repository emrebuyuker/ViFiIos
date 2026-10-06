import Foundation
import Testing
@testable import ViFi

/// Every test gets its own `UserDefaults` suite, deleted afterwards.
@Suite("RecentExamsStore")
final class RecentExamsStoreTests {
    private let storage: TemporaryDefaults

    init() throws {
        storage = try TemporaryDefaults()
    }

    @Test("A new store is empty")
    func startsEmpty() {
        #expect(makeStore().exams.isEmpty)
    }

    @Test("Recording stores the exam's path, kind and date")
    func recordStoresDetails() {
        let store = makeStore()

        store.record(path: Fixture.pdfExam, kind: .pdf, at: date(1))

        #expect(store.exams == [RecentExam(path: Fixture.pdfExam, kind: .pdf, openedAt: date(1))])
    }

    @Test("The most recently opened exam comes first")
    func newestFirst() {
        let store = makeStore()

        store.record(path: exam(1), kind: .images, at: date(1))
        store.record(path: exam(2), kind: .pdf, at: date(2))
        store.record(path: exam(3), kind: .images, at: date(3))

        #expect(store.exams.map(\.path) == [exam(3), exam(2), exam(1)])
    }

    @Test("Opening an exam again moves it to the top without duplicating it")
    func recordingAgainMovesToTop() {
        let store = makeStore()
        store.record(path: exam(1), kind: .images, at: date(1))
        store.record(path: exam(2), kind: .images, at: date(2))

        store.record(path: exam(1), kind: .images, at: date(3))

        #expect(store.exams.map(\.path) == [exam(1), exam(2)])
        #expect(store.exams.first?.openedAt == date(3))
    }

    @Test("Only the ten most recent exams are kept")
    func keepsTheNewestTen() {
        let store = makeStore()

        for number in 1...12 {
            store.record(path: exam(number), kind: .images, at: date(number))
        }

        #expect(RecentExamsStore.maxCount == 10)
        #expect(store.exams.map(\.path) == (3...12).reversed().map(exam))
    }

    @Test("Recorded exams are restored by a new store on the same defaults")
    func persistsAcrossInstances() {
        let store = makeStore()
        store.record(path: exam(1), kind: .images, at: date(1))
        store.record(path: Fixture.pdfExam, kind: .pdf, at: date(2))

        #expect(makeStore().exams == store.exams)
    }

    @Test("Removing an exam takes it off the list and persists")
    func remove() throws {
        let store = makeStore()
        for number in 1...3 {
            store.record(path: exam(number), kind: .images, at: date(number))
        }
        let middle = try #require(store.exams.first { $0.path == exam(2) })

        store.remove(middle)

        #expect(store.exams.map(\.path) == [exam(3), exam(1)])
        #expect(makeStore().exams == store.exams)
    }

    @Test("Removing an exam that is not listed changes nothing")
    func removeUnknown() {
        let store = makeStore()
        store.record(path: exam(1), kind: .images, at: date(1))

        store.remove(RecentExam(path: exam(9), kind: .pdf, openedAt: date(9)))

        #expect(store.exams.map(\.path) == [exam(1)])
    }

    @Test("Clearing empties the list and persists")
    func clear() {
        let store = makeStore()
        store.record(path: exam(1), kind: .images, at: date(1))
        store.record(path: exam(2), kind: .pdf, at: date(2))

        store.clear()

        #expect(store.exams.isEmpty)
        #expect(makeStore().exams.isEmpty)
    }

    @Test("A recent exam is titled by the exam and subtitled by university and lesson")
    func titleAndSubtitle() {
        let recent = RecentExam(path: Fixture.imagesExam, kind: .images, openedAt: date(1))

        #expect(recent.id == Fixture.imagesExam)
        #expect(recent.title == "2019 FİNAL")
        #expect(recent.subtitle == "BOZOK ÜNİVERSİTESİ › MÜHENDİSLİK MATEMATİĞİ")
    }

    // MARK: - Helpers

    private func makeStore() -> RecentExamsStore {
        RecentExamsStore(defaults: storage.defaults)
    }

    private func exam(_ number: Int) -> ArchivePath {
        Fixture.lesson.appending("\(2000 + number) VİZE")
    }

    /// Whole seconds, so dates survive JSON encoding exactly.
    private func date(_ minutes: Int) -> Date {
        Date(timeIntervalSinceReferenceDate: 800_000_000 + TimeInterval(minutes * 60))
    }
}

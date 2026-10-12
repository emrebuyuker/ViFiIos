import Foundation
import Testing
@testable import ViFi

/// Every test gets its own `UserDefaults` suite and a hand-moved clock.
@Suite("ArchivePrefetcher")
final class ArchivePrefetcherTests {
    private let storage: TemporaryDefaults
    private let clock = TestClock()

    init() throws {
        storage = try TemporaryDefaults()
    }

    @Test("A fresh prefetcher warms the archive once")
    func warmsOnFirstRun() async {
        let repository = StubArchiveRepository()

        await makePrefetcher(repository).prefetchIfNeeded()

        #expect(repository.prefetchCallCount == 1)
    }

    @Test("A second run within the throttle window is skipped")
    func throttlesRepeatRuns() async {
        let repository = StubArchiveRepository()
        let prefetcher = makePrefetcher(repository)

        await prefetcher.prefetchIfNeeded()
        clock.advance(by: ArchivePrefetcher.throttle - 1)
        await prefetcher.prefetchIfNeeded()

        #expect(repository.prefetchCallCount == 1)
    }

    @Test("A run after the throttle window warms again")
    func rewarmsAfterThrottle() async {
        let repository = StubArchiveRepository()
        let prefetcher = makePrefetcher(repository)

        await prefetcher.prefetchIfNeeded()
        clock.advance(by: ArchivePrefetcher.throttle)
        await prefetcher.prefetchIfNeeded()

        #expect(repository.prefetchCallCount == 2)
    }

    @Test("A recent warm by another instance on the same defaults is not repeated")
    func persistsAcrossInstances() async {
        await makePrefetcher(StubArchiveRepository()).prefetchIfNeeded()

        let laterRepository = StubArchiveRepository()
        await makePrefetcher(laterRepository).prefetchIfNeeded()

        #expect(laterRepository.prefetchCallCount == 0)
    }

    @Test("A failed warm is not recorded, so the next run retries")
    func retriesAfterFailure() async {
        let repository = StubArchiveRepository()
        repository.prefetchReplies = [.failure(ArchiveError.offline)]
        let prefetcher = makePrefetcher(repository)

        await prefetcher.prefetchIfNeeded()
        await prefetcher.prefetchIfNeeded()

        #expect(repository.prefetchCallCount == 2)
    }

    @Test("A warm that follows a failure is recorded and then throttled")
    func recordsWarmAfterRecovery() async {
        let repository = StubArchiveRepository()
        repository.prefetchReplies = [.failure(ArchiveError.offline), .success(())]
        let prefetcher = makePrefetcher(repository)

        await prefetcher.prefetchIfNeeded() // fails, nothing recorded
        await prefetcher.prefetchIfNeeded() // succeeds, records the time
        await prefetcher.prefetchIfNeeded() // throttled by the recorded time

        #expect(repository.prefetchCallCount == 2)
    }

    @Test("A cancelled warm is not recorded, so the next run retries")
    func retriesAfterCancellation() async {
        let repository = StubArchiveRepository()
        repository.prefetchReplies = [.failure(CancellationError())]
        let prefetcher = makePrefetcher(repository)

        await prefetcher.prefetchIfNeeded()
        await prefetcher.prefetchIfNeeded()

        #expect(repository.prefetchCallCount == 2)
    }

    @Test("A second warm started while one is in flight is dropped, not duplicated")
    func dropsConcurrentWarm() async {
        let gate = AsyncGate()
        let repository = StubArchiveRepository(gate: gate)
        let prefetcher = makePrefetcher(repository)

        // The first warm parks mid-fetch at the gate, so it is still in flight.
        async let firstWarm: Void = prefetcher.prefetchIfNeeded()
        await gate.waitForArrival()

        // A second warm started while the first is in flight must be dropped by the in-flight guard: it must
        // not reach the repository (which would be a duplicate whole-archive read). The throttle cannot cover
        // this, because the timestamp is only recorded after the first warm completes.
        async let secondWarm: Void = prefetcher.prefetchIfNeeded()
        let reachedRepositoryTwice = await eventually(timeout: .milliseconds(200)) {
            repository.prefetchCallCount == 2
        }

        gate.open()
        _ = await (firstWarm, secondWarm)

        #expect(reachedRepositoryTwice == false)
        #expect(repository.prefetchCallCount == 1)
    }

    // MARK: - Helpers

    private func makePrefetcher(_ repository: StubArchiveRepository) -> ArchivePrefetcher {
        ArchivePrefetcher(repository: repository, defaults: storage.defaults, now: clock.now)
    }
}

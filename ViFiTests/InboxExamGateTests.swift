import Foundation
import Testing
@testable import ViFi

/// The inbox's "Sınava Git" (`InboxExamGate`): opens only what the archive's lock rule allows, offers the unlock
/// sheet for a locked exam, and reports what cannot be opened.
@MainActor
@Suite("InboxExamGate")
struct InboxExamGateTests {
    private static func target(_ id: String) -> NotificationExamTarget {
        NotificationExamTarget(
            examId: id,
            path: ExamAccessResolverTests.course.appending(id: id, displayName: id),
            kind: .images
        )
    }

    private func check(
        _ gate: InboxExamGate,
        _ id: String,
        repository: StubArchiveRepository = StubArchiveRepository(items: [.success(ExamAccessResolverTests.courseExams)]),
        isSubscribed: Bool = false,
        unlockedIds: Set<String> = []
    ) async -> Bool {
        await gate.check(Self.target(id), repository: repository, isSubscribed: isSubscribed, unlockedIds: unlockedIds)
    }

    @Test("Free, unlocked and subscriber exams open straight away")
    func opens() async {
        let gate = InboxExamGate()
        #expect(await check(gate, "old-1"))
        #expect(await check(gate, "new-1", unlockedIds: ["new-1"]))
        #expect(await check(gate, "new-1", isSubscribed: true))
        #expect(gate.lockedExam == nil)
        #expect(gate.errorMessage == nil)
        #expect(gate.checkingExamId == nil)
    }

    @Test("A locked exam does not open; the unlock sheet is offered for it")
    func locked() async {
        let gate = InboxExamGate()

        #expect(await check(gate, "new-1") == false)

        #expect(gate.lockedExam == ExamAccessResolverTests.exam("new-1"))
        #expect(gate.errorMessage == nil)
    }

    @Test("Unlocking opens the exam once the sheet is gone")
    func unlockedThenOpens() async {
        let gate = InboxExamGate()
        _ = await check(gate, "new-1")

        gate.unlocked()
        gate.lockedExam = nil // the sheet dismisses itself

        #expect(gate.takeFollowUp() == .open(Self.target("new-1")))
        #expect(gate.takeFollowUp() == nil, "A follow-up runs once")
    }

    @Test("Earning coins or going Premium closes the sheet, then shows that")
    func leaving() async {
        let gate = InboxExamGate()
        _ = await check(gate, "new-1")
        gate.leaveForAddExam()
        #expect(gate.lockedExam == nil)
        #expect(gate.takeFollowUp() == .addExam)

        _ = await check(gate, "new-2")
        gate.leaveForPaywall()
        #expect(gate.lockedExam == nil)
        #expect(gate.takeFollowUp() == .paywall)
    }

    @Test("Closing the sheet without unlocking does nothing more")
    func closedWithoutUnlocking() async {
        let gate = InboxExamGate()
        _ = await check(gate, "new-1")
        gate.lockedExam = nil
        #expect(gate.takeFollowUp() == nil)
    }

    @Test("An exam that is no longer in the archive is explained, not opened")
    func missing() async {
        let gate = InboxExamGate()
        #expect(await check(gate, "deleted") == false)
        #expect(gate.errorMessage == "Bu sınav artık arşivde bulunmuyor.")
        #expect(gate.lockedExam == nil)
    }

    @Test("A course that cannot be loaded reports why and opens nothing")
    func failure() async {
        let gate = InboxExamGate()
        let repository = StubArchiveRepository(items: [.failure(ArchiveError.offline)])
        #expect(await check(gate, "new-1", repository: repository) == false)
        #expect(gate.errorMessage == ArchiveError.offline.userMessage)
        #expect(gate.lockedExam == nil)
    }

    @Test("A second tap while the course loads is ignored")
    func doubleTap() async {
        let gate = InboxExamGate()
        let asyncGate = AsyncGate()
        let repository = StubArchiveRepository(items: [.success(ExamAccessResolverTests.courseExams)], gate: asyncGate)
        let first = Task { await check(gate, "old-1", repository: repository) }
        await asyncGate.waitForArrival()
        #expect(gate.checkingExamId == "old-1")

        #expect(await check(gate, "old-2", repository: repository) == false)

        asyncGate.open()
        #expect(await first.value)
        #expect(repository.requestedItemPaths.count == 1)
        #expect(gate.checkingExamId == nil)
    }
}

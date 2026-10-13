import Testing
@testable import ViFi

@Suite("ExamLock")
struct ExamLockTests {
    private func exam(_ id: String) -> ArchiveItem {
        ArchiveItem(
            path: ArchivePath(components: ["uni", "fac", "dep", "course", id]),
            level: .exam,
            childCount: nil,
            exam: ExamSummary(kind: .images, fileCount: 1)
        )
    }

    @Test("The oldest (last) two exams are free")
    func freeIdsAreLastTwo() {
        // Exam lists are newest-first, so the oldest two are the last two.
        let exams = ["2020", "2019", "2018", "2017", "2016"].map(exam)
        #expect(ExamLock.freeExamIds(orderedExams: exams) == ["2017", "2016"])
    }

    @Test("Fewer exams than the free count means all are free")
    func fewerThanFreeCount() {
        #expect(ExamLock.freeExamIds(orderedExams: [exam("2020")]) == ["2020"])
        #expect(ExamLock.freeExamIds(orderedExams: []).isEmpty)
    }

    @Test("A free exam is accessible")
    func freeIsAccessible() {
        #expect(ExamLock.isAccessible(exam("2016"), freeIds: ["2016"], unlockedIds: []))
    }

    @Test("An unlocked exam is accessible")
    func unlockedIsAccessible() {
        #expect(ExamLock.isAccessible(exam("2020"), freeIds: [], unlockedIds: ["2020"]))
    }

    @Test("A non-free, non-unlocked exam is locked")
    func lockedExam() {
        #expect(ExamLock.isAccessible(exam("2020"), freeIds: ["2016"], unlockedIds: []) == false)
    }

    @Test("A non-exam entry is always accessible")
    func nonExamAccessible() {
        let university = ArchiveItem(
            path: ArchivePath(components: ["uni"]), level: .university, childCount: 1, exam: nil
        )
        #expect(ExamLock.isAccessible(university, freeIds: [], unlockedIds: []))
    }

    @Test("The cost matches the server function")
    func cost() {
        #expect(ExamLock.unlockCost == 100)
        #expect(ExamLock.freeCount == 2)
    }
}

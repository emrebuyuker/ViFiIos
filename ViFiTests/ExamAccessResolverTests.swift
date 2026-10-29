import Foundation
import Testing
@testable import ViFi

/// The archive's lock rule applied to an exam reached by its path alone (a notification): `ExamLock.isLocked`, the
/// rule `BrowseView` shows, and `ExamAccessResolver`, which loads the course only when it has to.
@MainActor
@Suite("Exam access (lock rule)")
struct ExamAccessResolverTests {
    static let course = ArchivePath(
        components: ["uni", "uni__fac", "uni__fac__dep", "uni__fac__dep__course"],
        displayNames: ["Üniversite", "Fakülte", "Bölüm", "Ders"]
    )

    static func exam(_ id: String, files: Int = 1) -> ArchiveItem {
        ArchiveItem(
            path: course.appending(id: id, displayName: id.uppercased()),
            level: .exam,
            childCount: nil,
            exam: files > 0 ? ExamSummary(kind: .images, fileCount: files) : nil
        )
    }

    /// Newest first, like every exam list: `old-1` and `old-2` are the free ones.
    static let courseExams = [exam("new-1"), exam("new-2"), exam("no-files", files: 0), exam("old-1"), exam("old-2")]

    private func decide(
        _ id: String,
        exams: [ArchiveItem] = courseExams,
        isSubscribed: Bool = false,
        unlockedIds: Set<String> = []
    ) async throws -> (ExamAccessDecision, StubArchiveRepository) {
        let repository = StubArchiveRepository(items: [.success(exams)])
        let decision = try await ExamAccessResolver.decision(
            for: Self.course.appending(id: id, displayName: id),
            repository: repository,
            isSubscribed: isSubscribed,
            unlockedIds: unlockedIds
        )
        return (decision, repository)
    }

    // MARK: ExamLock.isLocked (the archive's rule)

    @Test("isLocked: a newer exam is locked unless unlocked or subscribed; the oldest two and file-less ones never")
    func isLockedRule() {
        let free = ExamLock.freeExamIds(orderedExams: Self.courseExams)
        #expect(free == ["old-1", "old-2"])
        let locked = { (item: ArchiveItem, unlocked: Set<String>, subscribed: Bool) in
            ExamLock.isLocked(item, freeIds: free, unlockedIds: unlocked, isSubscribed: subscribed)
        }
        #expect(locked(Self.exam("new-1"), [], false))
        #expect(!locked(Self.exam("new-1"), ["new-1"], false))
        #expect(!locked(Self.exam("new-1"), [], true))
        #expect(!locked(Self.exam("old-2"), [], false))
        #expect(!locked(Self.exam("no-files", files: 0), [], false))
        let course = ArchiveItem(path: Self.course, level: .lesson, childCount: 5, exam: nil)
        #expect(!locked(course, [], false))
    }

    // MARK: Resolver

    @Test("A subscriber opens any exam without loading the course")
    func subscriber() async throws {
        let (decision, repository) = try await decide("new-1", isSubscribed: true)
        #expect(decision == .open)
        #expect(repository.requestedItemPaths.isEmpty)
    }

    @Test("An exam the user already unlocked opens without loading the course")
    func alreadyUnlocked() async throws {
        let (decision, repository) = try await decide("new-2", unlockedIds: ["new-2"])
        #expect(decision == .open)
        #expect(repository.requestedItemPaths.isEmpty)
    }

    @Test("A free (oldest) exam opens, judged from the course's full list")
    func freeExam() async throws {
        let (decision, repository) = try await decide("old-1", unlockedIds: ["new-1"])
        #expect(decision == .open)
        #expect(repository.requestedItemPaths == [Self.course])
    }

    @Test("A locked exam asks to be unlocked, with the archive's own entry")
    func lockedExam() async throws {
        let (decision, _) = try await decide("new-1", unlockedIds: ["new-2"])
        #expect(decision == .locked(Self.exam("new-1")))
    }

    @Test("An exam that is gone, or has no files, is unavailable")
    func unavailable() async throws {
        #expect(try await decide("deleted").0 == .unavailable)
        #expect(try await decide("no-files").0 == .unavailable)
    }

    @Test("A path that is not an exam's is unavailable without a request")
    func notAnExamPath() async throws {
        let repository = StubArchiveRepository()
        let decision = try await ExamAccessResolver.decision(
            for: Self.course, repository: repository, isSubscribed: false, unlockedIds: []
        )
        #expect(decision == .unavailable)
        #expect(repository.requestedItemPaths.isEmpty)
    }

    @Test("A course that cannot be loaded is an error, never an open exam")
    func loadFailure() async {
        let repository = StubArchiveRepository(items: [.failure(ArchiveError.offline)])
        await #expect(throws: ArchiveError.offline) {
            try await ExamAccessResolver.decision(
                for: Self.course.appending(id: "new-1", displayName: "x"),
                repository: repository,
                isSubscribed: false,
                unlockedIds: []
            )
        }
    }
}

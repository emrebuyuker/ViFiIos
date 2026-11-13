import Foundation
import Testing
@testable import ViFi

@Suite("ExamRouting")
struct ExamRoutingTests {
    private let path = Fixture.imagesExam

    @Test("A structured exam always opens the question screen")
    func structuredOpensQuestions() {
        let route = ExamRouting.route(for: path, kind: .images, questionCount: 12)

        #expect(route == .questions(path, .images))
    }

    @Test("No questions keeps the file viewer", arguments: [nil, 0] as [Int?])
    func fileViewer(questionCount: Int?) {
        let route = ExamRouting.route(for: path, kind: .pdf, questionCount: questionCount)

        #expect(route == .exam(path, .pdf))
    }

    @Test("A list item routes by its summary")
    func itemRoute() {
        let structured = ArchiveItem(
            path: path, level: .exam, childCount: nil, exam: ExamSummary(kind: .images, fileCount: 3, questionCount: 5)
        )
        let plain = ArchiveItem(path: path, level: .exam, childCount: nil, exam: ExamSummary(kind: .images, fileCount: 3))
        let empty = ArchiveItem(path: path, level: .exam, childCount: nil, exam: nil)

        #expect(structured.route() == .questions(path, .images))
        #expect(plain.route() == .exam(path, .images))
        #expect(empty.route() == nil)
    }

    @Test("The router opens the question screen with the archive's ancestors on the stack")
    func routerOpensQuestions() {
        let router = Router()

        router.openExam(at: path, kind: .images, questionCount: 4)

        #expect(router.path.last == .questions(path, .images))
        #expect(router.path.count == path.depth)
    }

    @Test("Recents and notifications open the file viewer, which redirects once it sees the exam is structured")
    func redirect() {
        let structured = ExamDocument(path: path, kind: .images, fileURLs: [], questionCount: 3)
        let plain = Fixture.document(kind: .images)

        #expect(ExamRouting.redirect(for: structured) == .questions(path, .images))
        #expect(ExamRouting.redirect(for: plain) == nil)
    }

    @Test("The file viewer's view model leaves the visit to the question screen when it redirects")
    func redirectedVisitNotRecordedTwice() async throws {
        let storage = try TemporaryDefaults()
        let recents = RecentExamsStore(defaults: storage.defaults)
        let analytics = AnalyticsSpy()
        let structured = ExamDocument(path: path, kind: .images, fileURLs: [], questionCount: 3)
        let viewModel = ExamDocumentViewModel(
            path: path,
            repository: StubArchiveRepository(documents: [.success(structured)]),
            recents: recents,
            analytics: analytics
        )

        await viewModel.load()

        #expect(viewModel.structuredRedirect == .questions(path, .images))
        #expect(recents.exams.isEmpty)
        #expect(analytics.events.isEmpty)
    }

    @Test("A plain exam is not redirected and the file viewer records its visit")
    func plainExamRecordsFileVisit() async throws {
        let storage = try TemporaryDefaults()
        let recents = RecentExamsStore(defaults: storage.defaults)
        let analytics = AnalyticsSpy()
        let plain = Fixture.document(kind: .images)
        let viewModel = ExamDocumentViewModel(
            path: path,
            repository: StubArchiveRepository(documents: [.success(plain)]),
            recents: recents,
            analytics: analytics
        )

        await viewModel.load()

        #expect(viewModel.structuredRedirect == nil)
        #expect(analytics.events == [.examOpened(kind: .images)])
    }

    @Test("The lock rule is unchanged: a structured exam is locked like any other")
    func lockPassthrough() {
        func exam(_ id: String, questions: Int?) -> ArchiveItem {
            ArchiveItem(
                path: ExamAccessResolverTests.course.appending(id: id, displayName: id), level: .exam, childCount: nil,
                exam: ExamSummary(kind: .images, fileCount: 1, questionCount: questions)
            )
        }
        let exams = [exam("new", questions: 5), exam("mid", questions: nil), exam("old-1", questions: 5), exam("old-2", questions: 5)]
        let free = ExamLock.freeExamIds(orderedExams: exams)

        #expect(ExamLock.isLocked(exams[0], freeIds: free, unlockedIds: [], isSubscribed: false))
        #expect(!ExamLock.isLocked(exams[0], freeIds: free, unlockedIds: ["new"], isSubscribed: false))
        #expect(!ExamLock.isLocked(exams[0], freeIds: free, unlockedIds: [], isSubscribed: true))
        #expect(!ExamLock.isLocked(exams[2], freeIds: free, unlockedIds: [], isSubscribed: false))
    }
}

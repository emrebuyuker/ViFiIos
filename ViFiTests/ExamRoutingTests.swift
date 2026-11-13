import Foundation
import Testing
@testable import ViFi

@Suite("ExamRouting")
struct ExamRoutingTests {
    private let path = Fixture.imagesExam

    @Test("A structured exam opens the question screen while the switch is on")
    func structuredOpensQuestions() {
        let route = ExamRouting.route(for: path, kind: .images, questionCount: 12, structuredEnabled: true)

        #expect(route == .questions(path, .images))
    }

    @Test("The switch off, or no questions, keeps the file viewer", arguments: [
        (12 as Int?, false), (nil, true), (nil, false), (0, true),
    ])
    func fileViewer(questionCount: Int?, enabled: Bool) {
        let route = ExamRouting.route(for: path, kind: .pdf, questionCount: questionCount, structuredEnabled: enabled)

        #expect(route == .exam(path, .pdf))
    }

    @Test("A list item routes by its summary")
    func itemRoute() {
        let structured = ArchiveItem(
            path: path, level: .exam, childCount: nil, exam: ExamSummary(kind: .images, fileCount: 3, questionCount: 5)
        )
        let plain = ArchiveItem(path: path, level: .exam, childCount: nil, exam: ExamSummary(kind: .images, fileCount: 3))
        let empty = ArchiveItem(path: path, level: .exam, childCount: nil, exam: nil)

        #expect(structured.route(structuredEnabled: true) == .questions(path, .images))
        #expect(structured.route(structuredEnabled: false) == .exam(path, .images))
        #expect(plain.route(structuredEnabled: true) == .exam(path, .images))
        #expect(empty.route(structuredEnabled: true) == nil)
    }

    @Test("The router opens the question screen with the archive's ancestors on the stack")
    func routerOpensQuestions() {
        let router = Router()

        router.openExam(at: path, kind: .images, questionCount: 4, structuredEnabled: true)

        #expect(router.path.last == .questions(path, .images))
        #expect(router.path.count == path.depth)
    }

    @Test("Recents and notifications open the file viewer, which redirects once it sees the exam is structured")
    func redirect() {
        let structured = ExamDocument(path: path, kind: .images, fileURLs: [], questionCount: 3)
        let plain = Fixture.document(kind: .images)

        #expect(ExamRouting.redirect(for: structured, structuredEnabled: true) == .questions(path, .images))
        #expect(ExamRouting.redirect(for: structured, structuredEnabled: false) == nil)
        #expect(ExamRouting.redirect(for: plain, structuredEnabled: true) == nil)
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
            analytics: analytics,
            structuredEnabled: true
        )

        await viewModel.load()

        #expect(viewModel.structuredRedirect == .questions(path, .images))
        #expect(recents.exams.isEmpty)
        #expect(analytics.events.isEmpty)
    }

    @Test("With the switch off the file viewer records the visit of a structured exam as usual")
    func switchOffRecordsFileVisit() async throws {
        let storage = try TemporaryDefaults()
        let recents = RecentExamsStore(defaults: storage.defaults)
        let analytics = AnalyticsSpy()
        let structured = ExamDocument(path: path, kind: .images, fileURLs: [], questionCount: 3)
        let viewModel = ExamDocumentViewModel(
            path: path,
            repository: StubArchiveRepository(documents: [.success(structured)]),
            recents: recents,
            analytics: analytics,
            structuredEnabled: false
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

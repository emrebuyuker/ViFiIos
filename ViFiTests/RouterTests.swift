import Testing
@testable import ViFi

@Suite("Router")
struct RouterTests {
    private let lesson = Fixture.lesson

    @Test("push appends a route")
    func push() {
        let router = Router()

        router.push(.browse(lesson.prefix(1)))
        router.push(.exam(Fixture.imagesExam, .images))

        #expect(router.path == [.browse(lesson.prefix(1)), .exam(Fixture.imagesExam, .images)])
    }

    @Test("popToRoot empties the stack")
    func popToRoot() {
        let router = drilledDown(to: lesson)

        router.popToRoot()

        #expect(router.path.isEmpty)
    }

    @Test("popTo an ancestor keeps its route and drops the ones above it", arguments: 1...3)
    func popToAncestor(_ depth: Int) {
        let router = drilledDown(to: lesson)

        router.popTo(lesson.prefix(depth))

        #expect(router.path == browseRoutes(to: lesson.prefix(depth)))
    }

    @Test("popTo the root path empties the stack")
    func popToRootPath() {
        let router = drilledDown(to: lesson)

        router.popTo(.root)

        #expect(router.path.isEmpty)
    }

    @Test("popTo the current list leaves the stack unchanged")
    func popToCurrent() {
        let router = drilledDown(to: lesson)

        router.popTo(lesson)

        #expect(router.path == browseRoutes(to: lesson))
    }

    @Test("openExam stacks every ancestor list below the exam", arguments: ExamKind.allCases)
    func openExam(_ kind: ExamKind) {
        let router = Router()

        router.openExam(at: Fixture.imagesExam, kind: kind)

        #expect(router.path == browseRoutes(to: lesson) + [.exam(Fixture.imagesExam, kind)])
    }

    @Test("openExam replaces whatever stack was shown")
    func openExamReplacesStack() {
        let router = drilledDown(to: ArchivePath(components: ["KOCAELİ ÜNİVERSİTESİ", "MÜHENDİSLİK FAKÜLTESİ"]))

        router.openExam(at: Fixture.pdfExam, kind: .pdf)

        #expect(router.path == browseRoutes(to: lesson) + [.exam(Fixture.pdfExam, .pdf)])
    }

    @Test("A breadcrumb tap after openExam returns to that ancestor")
    func popToAfterOpenExam() {
        let router = Router()
        router.openExam(at: Fixture.imagesExam, kind: .images)

        router.popTo(lesson.prefix(2))

        #expect(router.path == browseRoutes(to: lesson.prefix(2)))
    }

    // MARK: - Helpers

    /// The routes pushed by drilling down from the home screen to the list at `path`.
    private func browseRoutes(to path: ArchivePath) -> [Route] {
        (0..<path.depth).map { .browse(path.prefix($0 + 1)) }
    }

    /// A router showing the list at `path`, reached by drilling down from the home screen.
    private func drilledDown(to path: ArchivePath) -> Router {
        let router = Router()
        for route in browseRoutes(to: path) {
            router.push(route)
        }
        return router
    }
}

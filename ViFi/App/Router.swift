import Observation

/// A screen pushed on the navigation stack. The root screen (university list) is not a route.
enum Route: Hashable {
    /// The list of entries under `path` (faculties, departments, lessons or exams).
    case browse(ArchivePath)
    /// The viewer of the exam at `path`.
    case exam(ArchivePath, ExamKind)
    /// The structured question screen of the exam at `path` (4.2.0). `ExamKind` is the original files' kind, kept
    /// for the recents entry.
    case questions(ArchivePath, ExamKind)
}

/// Owns the navigation stack so any screen can go home, jump to a breadcrumb or deep-link.
@Observable
final class Router {
    var path: [Route] = []

    func push(_ route: Route) {
        path.append(route)
    }

    func popToRoot() {
        path.removeAll()
    }

    /// Shows the list at `archivePath`, keeping its ancestors on the stack (breadcrumb tap).
    func popTo(_ archivePath: ArchivePath) {
        guard !archivePath.isRoot else {
            popToRoot()
            return
        }
        path = Array(path.prefix(archivePath.depth))
    }

    /// Opens an exam with its whole hierarchy on the stack, so Back walks up the archive.
    ///
    /// Callers that only know the exam's file kind (recents, notifications) open the file viewer; it replaces
    /// itself with the question screen once it sees the exam is structured (`ExamRouting.redirect`).
    func openExam(at examPath: ArchivePath, kind: ExamKind, questionCount: Int? = nil) {
        let ancestors = (1..<examPath.depth).map { Route.browse(examPath.prefix($0)) }
        let route = ExamRouting.route(for: examPath, kind: kind, questionCount: questionCount)
        path = ancestors + [route]
    }
}

import Foundation

/// The one decision behind opening an exam: the structured question screen (4.2.0) or today's file viewer.
///
/// Pure so it is unit-tested. An exam opens the question screen only when it is `format == "structured"` **and**
/// it has questions (`questionCount > 0`); otherwise it opens the original files, which structured exams keep for
/// old clients. There is no remote switch (App Review). The lock rule is not part of this decision and is unchanged: a locked exam never gets
/// here (`ExamLock`, `ExamAccessResolver`).
nonisolated enum ExamRouting {
    /// The route for an exam whose list summary is known (Browse and search results).
    static func route(for path: ArchivePath, kind: ExamKind, questionCount: Int?) -> Route {
        opensQuestions(questionCount: questionCount)
            ? .questions(path, kind)
            : .exam(path, kind)
    }

    static func opensQuestions(questionCount: Int?) -> Bool {
        (questionCount ?? 0) > 0
    }

    /// For a file viewer opened without a summary (recents, a tapped notification) that has now loaded the exam's
    /// document: the question route to replace it with, or `nil` to stay.
    static func redirect(for document: ExamDocument) -> Route? {
        guard opensQuestions(questionCount: document.questionCount) else { return nil }
        return .questions(document.path, document.kind)
    }
}

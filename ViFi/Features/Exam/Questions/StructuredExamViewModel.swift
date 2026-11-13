import Foundation
import Observation
import OSLog

/// Loads the questions of one structured exam, tracks which answers are revealed, and records the visit.
///
/// Only the lock-passed exam reaches this screen (the archive's `ExamLock` / `ExamAccessResolver` decide before the
/// route is pushed), so there is no extra gate here (K4: whoever can open the exam can reveal its answers).
@Observable
final class StructuredExamViewModel {
    let path: ArchivePath
    private(set) var state: Loadable<[ExamQuestion]> = .loading
    /// The `order` of every question whose answer is shown.
    private(set) var revealedOrders: Set<Int> = []

    @ObservationIgnored private let kind: ExamKind
    @ObservationIgnored private let reader: any ExamQuestionReading
    @ObservationIgnored private let recents: RecentExamsStore
    @ObservationIgnored private let analytics: any AnalyticsTracking
    @ObservationIgnored private var isFetching = false
    @ObservationIgnored private var hasRecordedVisit = false
    /// Questions whose first reveal was already counted (`answer_revealed` is once per question per screen).
    @ObservationIgnored private var trackedReveals: Set<Int> = []

    /// - Parameter kind: The kind of the exam's original files, kept for the recents entry.
    init(
        path: ArchivePath,
        kind: ExamKind,
        reader: any ExamQuestionReading,
        recents: RecentExamsStore,
        analytics: any AnalyticsTracking
    ) {
        self.path = path
        self.kind = kind
        self.reader = reader
        self.recents = recents
        self.analytics = analytics
    }

    var title: String { path.displayName ?? "" }

    /// "University › Lesson": where the exam comes from.
    var subtitle: String {
        [path.displayNames.first, path.displayNames.dropLast().last]
            .compactMap { $0 }
            .joined(separator: " › ")
    }

    /// A one-line reference to this exam for a "Bize Ulaş" e-mail.
    var supportContext: String {
        "Sınav: " + path.displayNames.joined(separator: " › ")
    }

    var questions: [ExamQuestion] { state.value ?? [] }

    /// The exam id the questions are read by (the last path component).
    private var examId: String? { path.components.last }

    /// Fetches the questions. Questions already on screen stay visible while reloading and when the reload fails.
    /// The visit is recorded (recents + `exam_open`) once, after the first load that has questions.
    func load() async {
        guard !isFetching else { return }
        guard let examId else {
            state = .failed(message: ArchiveError.notFound.userMessage)
            return
        }
        isFetching = true
        defer { isFetching = false }

        if state.value == nil {
            state = .loading
        }
        do {
            let questions = try await reader.questions(examId: examId)
            state = .loaded(questions)
            recordVisitIfNeeded(questionCount: questions.count)
        } catch {
            handleLoadFailure(error)
        }
    }

    /// Loads unless questions are already available. For `.task`, which runs again on every appearance.
    func loadIfNeeded() async {
        guard state.value == nil else { return }
        await load()
    }

    func isAnswerRevealed(order: Int) -> Bool {
        revealedOrders.contains(order)
    }

    /// Shows or hides a question's answer. The first reveal of each question is counted once.
    func toggleAnswer(order: Int) {
        if revealedOrders.remove(order) != nil { return }
        revealedOrders.insert(order)
        if trackedReveals.insert(order).inserted {
            analytics.track(.answerRevealed(order: order))
        }
    }

    // MARK: - Private

    private func recordVisitIfNeeded(questionCount: Int) {
        guard !hasRecordedVisit, questionCount > 0 else { return }
        hasRecordedVisit = true
        recents.record(path: path, kind: kind)
        analytics.track(.structuredExamOpened(questionCount: questionCount))
    }

    private func handleLoadFailure(_ error: any Error) {
        // Leaving the screen cancels the load: keep `.loading` so the next appearance retries.
        guard !Task.isCancelled, !(error is CancellationError) else { return }
        let location = path.components.joined(separator: "/")
        Logger.archive.error("Loading questions of \(location, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        if state.value == nil {
            state = .failed(message: error.userMessage)
        }
    }
}

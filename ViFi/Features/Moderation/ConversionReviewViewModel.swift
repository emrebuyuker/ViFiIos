import Foundation
import Observation

/// How the admin maps a published exam onto a country-wide course identity (`subjects/<id>`).
nonisolated enum SubjectMode: String, CaseIterable, Identifiable {
    /// The server's own suggestion (nothing is sent).
    case suggested
    /// An existing subject id the admin typed.
    case existing
    /// A new subject, by name.
    case new

    var id: String { rawValue }
}

/// What ended the review.
nonisolated enum ReviewOutcome: Equatable {
    case published(questionCount: Int)
    case discarded
    /// The whole exam was sent back to the AI; the job is `queued` again.
    case regenerating
}

/// Drives the second-approval review of one ready job: the draft questions, edits, per-question and whole-exam
/// regeneration (K8, K14), publishing with the course mapping and the exam's list title (K28), and "Sınavı iptal et".
@Observable
final class ConversionReviewViewModel {
    let job: ExamConversion
    private(set) var drafts: Loadable<[ExamQuestion]> = .loading
    private(set) var isWorking = false
    private(set) var outcome: ReviewOutcome?
    /// The last failed action.
    private(set) var errorMessage: String?
    /// A hint after a regeneration started (the draft changes once the server finishes).
    private(set) var infoMessage: String?

    var subjectMode: SubjectMode = .suggested
    var subjectId = ""
    var newSubjectName = ""

    /// The exam title the exam is published with (K28): `[<year> ]<list name>[ <1–99>]`. Pre-filled from the server's
    /// suggestion; empty (no name) when there is none, and publishing waits until a name is picked.
    var titleYear = ""
    var titleEntryId: String?
    var titleNumber = ""

    @ObservationIgnored private let service: any ExamConversionServicing
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let pollWindow: Duration
    @ObservationIgnored private var pollingTask: Task<Void, Never>?

    /// `pollInterval` / `pollWindow`: after a single-question regeneration the drafts are re-read every interval for at
    /// most the window (the server's lease is a few minutes; the admin should not have to pull to refresh).
    init(
        job: ExamConversion,
        service: any ExamConversionServicing,
        now: @escaping @Sendable () -> Date = { Date() },
        pollInterval: Duration = .seconds(5),
        pollWindow: Duration = .seconds(120)
    ) {
        self.job = job
        self.service = service
        self.now = now
        self.pollInterval = pollInterval
        self.pollWindow = pollWindow
        if let suggestion = job.suggestedTitle.flatMap(ExamListTitle.parse) {
            titleYear = suggestion.year.map(String.init) ?? ""
            titleEntryId = suggestion.entryId
            titleNumber = suggestion.number.map(String.init) ?? ""
        }
    }

    /// The list title the editor's parts make, normalised as the server stores it; `nil` while they are not valid.
    var examTitle: String? {
        guard titleProblem == nil, let titleEntryId else { return nil }
        let parts = ExamListTitle(
            year: ExamListTitle.year(trimmed(titleYear)), entryId: titleEntryId,
            number: ExamListTitle.sequenceNumber(trimmed(titleNumber))
        )
        return ExamListTitle.parse(parts.title)?.title
    }

    /// Why the title cannot be published yet, or `nil` when it can.
    var titleProblem: String? {
        guard let titleEntryId, ExamNameCatalog.entry(id: titleEntryId) != nil else {
            return String(localized: "Listeden bir ad seç")
        }
        let year = trimmed(titleYear)
        if !year.isEmpty, ExamListTitle.year(year) == nil {
            return String(localized: "Yıl 4 haneli olmalı (ör. 2019) ya da boş kalmalı.")
        }
        let number = trimmed(titleNumber)
        if !number.isEmpty {
            guard ExamListTitle.sequenceNumber(number) != nil else {
                return String(localized: "Sıra no 1–99 arasında olmalı ya da boş kalmalı.")
            }
            if titleEntryId.hasPrefix("kisa-sinav-") {
                return String(localized: "Bu ad zaten numaralı; sıra no boş kalmalı.")
            }
        }
        return nil
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether the server is regenerating `question` right now.
    func isRegenerating(_ question: ExamQuestion) -> Bool {
        question.isRegenerating(at: now())
    }

    /// Stops the automatic refresh (the screen went away).
    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Waits for the automatic refresh to end (tests).
    func waitForPolling() async {
        await pollingTask?.value
    }

    /// Draft questions the model was unsure about and nobody edited yet.
    var needsReviewCount: Int {
        drafts.value?.filter(\.needsReview).count ?? 0
    }

    var canPublish: Bool {
        !isWorking && outcome == nil && !(drafts.value?.isEmpty ?? true) && examTitle != nil
    }

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await load()
    }

    func refresh() async {
        await load()
    }

    /// Saves an edited draft question; the list shows the saved version. Returns whether it was saved.
    func save(_ question: ExamQuestion) async -> Bool {
        errorMessage = nil
        do {
            try await service.saveDraftQuestion(jobId: job.id, question: question)
            replace(question)
            return true
        } catch {
            errorMessage = error.userMessage
            return false
        }
    }

    func regenerateQuestion(order: Int, provider: AIProvider) async {
        await perform {
            try await self.service.regenerateQuestion(jobId: self.job.id, order: order, provider: provider)
            self.infoMessage = String(localized: "Soru \(order) yeniden üretiliyor; liste kendiliğinden yenilenir.")
            self.startPolling(order: order)
        }
    }

    /// Whether the automatic refresh after a single-question regeneration can stop. Pure, so the rules are testable:
    /// a running lease keeps it going; once a lease was seen it ends the run (finished or failed); before any lease
    /// was seen (the task has not claimed the draft yet) only a new error or a rewritten draft ends it.
    nonisolated static func pollShouldStop(
        question: ExamQuestion?, baseline: ExamQuestion?, sawLease: Bool, now: Date
    ) -> Bool {
        guard let question else { return true }
        if question.isRegenerating(at: now) { return false }
        if sawLease { return true }
        if question.regenerationError != nil && baseline?.regenerationError == nil { return true }
        return question.updatedAt != baseline?.updatedAt
    }

    private func startPolling(order: Int) {
        pollingTask?.cancel()
        let baseline = drafts.value?.first { $0.order == order }
        let attempts = max(1, Int((pollWindow / pollInterval).rounded(.down)))
        pollingTask = Task { [weak self, pollInterval] in
            var sawLease = false
            for _ in 0..<attempts {
                do { try await Task.sleep(for: pollInterval) } catch { return }
                guard let self, !Task.isCancelled else { return }
                await self.reloadQuietly()
                guard !Task.isCancelled else { return }
                let question = self.drafts.value?.first { $0.order == order }
                if question.map({ self.isRegenerating($0) }) == true { sawLease = true }
                if Self.pollShouldStop(question: question, baseline: baseline, sawLease: sawLease, now: self.now()) { return }
            }
        }
    }

    /// Re-reads the drafts without a loading state; a failed read keeps the list as it is.
    private func reloadQuietly() async {
        guard let fresh = try? await service.draftQuestions(jobId: job.id) else { return }
        drafts = .loaded(fresh)
    }

    /// K14: a second-approval rejection — the whole exam is generated again with the picked provider.
    func regenerateAll(provider: AIProvider) async {
        await perform {
            try await self.service.regenerate(jobId: self.job.id, provider: provider)
            self.outcome = .regenerating
        }
    }

    func publish() async {
        guard canPublish else { return }
        let subject: (id: String?, name: String?)
        switch subjectMode {
        case .suggested:
            subject = (nil, nil)
        case .existing:
            let id = subjectId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else {
                errorMessage = String(localized: "Ders kimliğini yaz ya da başka bir seçenek seç.")
                return
            }
            subject = (id, nil)
        case .new:
            let name = newSubjectName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                errorMessage = String(localized: "Yeni dersin adını yaz ya da başka bir seçenek seç.")
                return
            }
            subject = (nil, name)
        }
        guard let examTitle else { return }
        await perform {
            let result = try await self.service.publish(
                jobId: self.job.id, subjectId: subject.id, newSubjectName: subject.name, examTitle: examTitle
            )
            self.outcome = .published(questionCount: result.questionCount)
        }
    }

    func discard() async {
        await perform {
            try await self.service.discard(jobId: self.job.id)
            self.outcome = .discarded
        }
    }

    private func perform(_ action: () async throws -> Void) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        infoMessage = nil
        defer { isWorking = false }
        do {
            try await action()
        } catch {
            errorMessage = error.userMessage
        }
    }

    private func load() async {
        if drafts.value == nil { drafts = .loading }
        do {
            drafts = .loaded(try await service.draftQuestions(jobId: job.id))
        } catch is CancellationError {
            hasLoaded = false
        } catch {
            drafts = .failed(message: error.userMessage)
        }
    }

    private func replace(_ question: ExamQuestion) {
        guard var questions = drafts.value, let index = questions.firstIndex(where: { $0.order == question.order }) else { return }
        // Saving an edit clears the "look carefully" flag, as the server-side draft does.
        questions[index] = question.withNeedsReview(false)
        drafts = .loaded(questions)
    }
}

extension ExamQuestion {
    func withNeedsReview(_ needsReview: Bool) -> ExamQuestion {
        ExamQuestion(
            id: id, examId: examId, order: order, label: label, text: text, speech: speech, choices: choices,
            figures: figures, answer: answer, solution: solution, topics: topics, difficulty: difficulty,
            confidence: confidence, needsReview: needsReview, updatedAt: updatedAt,
            regeneratingUntil: regeneratingUntil, regenerationError: regenerationError
        )
    }
}

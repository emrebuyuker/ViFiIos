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
/// regeneration (K8, K14), publishing with the course mapping, and "Sınavı iptal et".
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

    @ObservationIgnored private let service: any ExamConversionServicing
    @ObservationIgnored private var hasLoaded = false

    init(job: ExamConversion, service: any ExamConversionServicing) {
        self.job = job
        self.service = service
    }

    /// Draft questions the model was unsure about and nobody edited yet.
    var needsReviewCount: Int {
        drafts.value?.filter(\.needsReview).count ?? 0
    }

    var canPublish: Bool {
        !isWorking && outcome == nil && !(drafts.value?.isEmpty ?? true)
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
            self.infoMessage = String(localized: "Soru \(order) yeniden üretiliyor; birkaç saniye sonra yenile.")
        }
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
        await perform {
            let result = try await self.service.publish(jobId: self.job.id, subjectId: subject.id, newSubjectName: subject.name)
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
            confidence: confidence, needsReview: needsReview, updatedAt: updatedAt
        )
    }
}

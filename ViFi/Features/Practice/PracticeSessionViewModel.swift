import Foundation
import Observation
import OSLog

/// One practice session: questions one at a time from the server. No right/wrong tracking and no end summary (owner
/// decisions P2, P3).
///
/// Premium fetches the next question ahead so the callable's latency stays hidden. Free users do not: the server counts
/// the daily limit when it *delivers* a question, so a prefetched question the user never reaches (they leave the
/// session) would spend one of their 5 daily questions for nothing. `exclude` carries the session's seen ids (newest
/// 300), so nothing repeats until the pool is exhausted and the user starts over.
@Observable
final class PracticeSessionViewModel {
    enum Phase: Equatable {
        /// Waiting for a question.
        case loading
        case question
        /// Every question of the pool was seen (the server returned none for the remaining ids).
        case exhausted
        /// The free daily limit is used up; the paywall is offered.
        case limitReached
        case failed(message: String)
    }

    let selection: PracticeSelection
    private(set) var phase: Phase = .loading
    private(set) var current: PracticeQuestion?
    private(set) var isAnswerRevealed = false
    /// The pool's size as the server last reported it.
    private(set) var poolSize: Int

    @ObservationIgnored private let service: any PracticeServicing
    @ObservationIgnored private let analytics: any AnalyticsTracking
    /// Delivered but not yet shown (at most the one prefetched question; Premium only).
    @ObservationIgnored private var queue: [PracticeQuestion] = []
    @ObservationIgnored private var seenIds: [String] = []
    /// The free questions left today as the server last reported it; `nil` for Premium or before the first answer.
    private var serverRemaining: Int?
    /// Free-limit state: no more questions can be delivered today.
    @ObservationIgnored private var isLimitHit = false
    /// The server has no unseen question left in the pool.
    @ObservationIgnored private var isPoolDone = false
    @ObservationIgnored private var lastError: String?
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var hasStarted = false
    @ObservationIgnored private var hasTrackedReveal = false
    @ObservationIgnored private var hasTrackedLimit = false
    @ObservationIgnored private var isAdvancing = false

    init(selection: PracticeSelection, service: any PracticeServicing, analytics: any AnalyticsTracking) {
        self.selection = selection
        self.service = service
        self.analytics = analytics
        poolSize = selection.poolCount
    }

    /// The free questions the user still has today; `nil` for Premium (no counter). Free users never hold a
    /// prefetched question, so `queue` is empty for them; it is added for safety.
    var remainingToday: Int? {
        serverRemaining.map { $0 + queue.count }
    }

    /// The ids sent as `exclude`: the newest `PracticeLimits.maxExclude` seen ones.
    var excludedIds: [String] {
        Array(seenIds.suffix(PracticeLimits.maxExclude))
    }

    /// Starts the session once (the screen's `.task` runs again on every appearance).
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        analytics.track(.practiceStarted(examType: selection.examType, scope: selection.scope))
        await advance()
    }

    /// "Sıradaki soru" (also the retry after a failure).
    func next() async {
        await advance()
    }

    /// "Baştan başla": forgets the seen ids and draws from the whole pool again.
    func restart() async {
        prefetchTask?.cancel()
        prefetchTask = nil
        queue = []
        seenIds = []
        isPoolDone = false
        current = nil
        phase = .loading
        await advance()
    }

    /// Reveals or hides the current answer; the first reveal of each question is counted.
    func toggleAnswer() {
        isAnswerRevealed.toggle()
        if isAnswerRevealed, !hasTrackedReveal {
            hasTrackedReveal = true
            analytics.track(.practiceAnswerRevealed)
        }
    }

    /// The paywall was opened from the limit screen.
    func paywallOpened() {
        analytics.track(.practicePaywallOpened)
    }

    /// Drops the prefetch when the screen goes away.
    func stop() {
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    // MARK: - Flow

    private func advance() async {
        guard !isAdvancing else { return }
        isAdvancing = true
        defer { isAdvancing = false }

        if queue.isEmpty {
            await prefetchTask?.value
        }
        if queue.isEmpty, !isLimitHit, !isPoolDone {
            if current == nil { phase = .loading }
            lastError = nil
            await fetchOne()
        }
        if !queue.isEmpty {
            show(queue.removeFirst())
        } else if let lastError {
            phase = .failed(message: lastError)
        } else if isLimitHit {
            showLimit()
        } else if isPoolDone {
            current = nil
            phase = .exhausted
        }
    }

    private func show(_ question: PracticeQuestion) {
        current = question
        isAnswerRevealed = false
        hasTrackedReveal = false
        phase = .question
        startPrefetch()
    }

    private func showLimit() {
        current = nil
        phase = .limitReached
        guard !hasTrackedLimit else { return }
        hasTrackedLimit = true
        analytics.track(.practiceLimitReached)
    }

    /// Premium only: after the first answer `serverRemaining` is `nil` for Premium and a number for free users.
    private func startPrefetch() {
        guard serverRemaining == nil, prefetchTask == nil, queue.isEmpty, !isLimitHit, !isPoolDone else { return }
        prefetchTask = Task { [weak self] in
            await self?.fetchOne()
            self?.prefetchTask = nil
        }
    }

    /// Asks the server for one more question and files the answer. A failure is remembered for the screen to show
    /// when it is needed (a failed prefetch stays silent until the user asks for the next question).
    private func fetchOne() async {
        let request = PracticeRequest(selection: selection, exclude: excludedIds, count: 1)
        do {
            let batch = try await service.nextQuestions(request)
            guard !Task.isCancelled else { return }
            apply(batch)
        } catch {
            guard !Task.isCancelled else { return }
            Logger.app.error("Practice question fetch failed: \(String(describing: error), privacy: .public)")
            lastError = error.userMessage
        }
    }

    private func apply(_ batch: PracticeBatch) {
        serverRemaining = batch.remainingToday
        poolSize = max(poolSize, batch.poolSize)
        let fresh = batch.questions.filter { !seenIds.contains($0.id) }
        for question in fresh {
            queue.append(question)
            seenIds.append(question.id)
        }
        if batch.limitReached || batch.remainingToday == 0 {
            // Free: nothing more can be delivered once today's last question is out.
            isLimitHit = true
        } else if fresh.isEmpty {
            // No unseen question came back (also guards a server that ignored `exclude`).
            isPoolDone = true
        }
    }
}

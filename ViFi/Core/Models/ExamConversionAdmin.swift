import Foundation

// Admin-side value types of the 4.2.0 conversion workflow (bulk queueing, AI spend, publishing). Shapes mirror the
// callable contract in `firebase/functions/conversions/schema.js` (`CALLABLES`).

/// What a bulk conversion covers: every unconverted exam of one course or of a whole department.
nonisolated enum BulkConversionScope: Hashable, Sendable {
    case course(id: String)
    case department(id: String)
}

/// The answer of `requestBulkConversion`: for a dry run, only the numbers; otherwise also the queued job ids.
nonisolated struct BulkConversionEstimate: Equatable, Sendable {
    let examCount: Int
    let estimatedCostUsd: Double
    let jobIds: [String]
}

/// The month's AI spend against the $50 cap (`aiUsage/<YYYY-MM>`, server-written; K11).
nonisolated struct AIMonthlyUsage: Equatable, Sendable {
    /// The monthly cap in US dollars (owner decision K11).
    static let capUsd = 50.0

    /// `YYYY-MM` in Europe/Istanbul.
    let month: String
    let costUsd: Double

    /// Spend as a share of the cap, clamped to 0…1 for the gauge.
    var fraction: Double { min(1, max(0, costUsd / Self.capUsd)) }

    /// Whether adding `extra` dollars would pass the cap.
    func exceedsCap(adding extra: Double) -> Bool { costUsd + extra > Self.capUsd }

    /// `YYYY-MM` of `date` in Europe/Istanbul (UTC+3 all year), as `usageMonthKey` on the server.
    static func monthKey(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 3 * 3600) ?? .gmt
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }
}

/// The answer of `publishExamConversion`.
nonisolated struct PublishedExamResult: Equatable, Sendable {
    let examId: String
    let questionCount: Int
}

/// Conversion workflow failures, with Turkish messages for the admin UI.
nonisolated enum ExamConversionError: LocalizedError, Equatable {
    case offline
    case permissionDenied
    case notFound
    /// The monthly AI budget is used up (`resource-exhausted`).
    case budgetExceeded
    /// The job or question is not in a state that allows the action (`failed-precondition`).
    case notAllowed(message: String)
    case invalidInput(message: String)
    case unknown(message: String)

    var errorDescription: String? {
        switch self {
        case .offline:
            String(localized: "İnternet bağlantısı yok. Bağlantını kontrol edip tekrar dene.")
        case .permissionDenied:
            String(localized: "Bu işlem için yetkin yok.")
        case .notFound:
            String(localized: "İş ya da soru bulunamadı; listeyi yenile.")
        case .budgetExceeded:
            String(localized: "Aylık yapay zekâ bütçesi doldu.")
        case let .notAllowed(message), let .invalidInput(message), let .unknown(message):
            message
        }
    }
}

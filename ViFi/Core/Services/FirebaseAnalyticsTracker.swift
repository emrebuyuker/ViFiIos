import FirebaseAnalytics

/// Reports anonymous usage events to Google Analytics for Firebase.
///
/// Only screen names, archive levels and file formats are sent — never archive names or anything
/// that could identify the user.
final class FirebaseAnalyticsTracker: AnalyticsTracking {
    init() {}

    func track(_ event: AnalyticsEvent) {
        Analytics.logEvent(event.firebaseName, parameters: event.firebaseParameters)
    }
}

// MARK: - Event mapping

private extension AnalyticsEvent {
    var firebaseName: String {
        switch self {
        case .screenView: AnalyticsEventScreenView
        case .browse: "browse_level"
        case .examOpened: "exam_open"
        case .examShared: "exam_share"
        case .recentExamOpened: "recent_exam_open"
        }
    }

    var firebaseParameters: [String: Any]? {
        switch self {
        case let .screenView(name):
            [AnalyticsParameterScreenName: name]
        case let .browse(level):
            ["level": level.analyticsName]
        case let .examOpened(kind), let .examShared(kind):
            ["kind": kind.rawValue]
        case .recentExamOpened:
            nil
        }
    }
}

private extension ArchiveLevel {
    /// Stable, language-independent names for reports.
    var analyticsName: String {
        switch self {
        case .university: "university"
        case .faculty: "faculty"
        case .department: "department"
        case .lesson: "lesson"
        case .exam: "exam"
        }
    }
}

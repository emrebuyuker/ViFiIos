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

    func setUser(_ user: AnalyticsUser?) {
        Analytics.setUserID(user?.id)
        // Set each known property; a name with no value (no profile, or sign-out) is cleared with nil, so the
        // next user is never mixed with the previous one.
        for name in AnalyticsUser.propertyNames {
            Analytics.setUserProperty(user?.properties[name], forName: name)
        }
    }
}

// MARK: - Event mapping

private extension AnalyticsEvent {
    var firebaseName: String {
        switch self {
        case .screenView: AnalyticsEventScreenView
        case .browse: "browse_level"
        case .examOpened: "exam_open"
        case .recentExamOpened: "recent_exam_open"
        case .examUnlockSheetShown: "unlock_sheet_shown"
        case .earnCoinsTapped: "earn_coins_tapped"
        case .examUnlocked: "exam_unlock"
        case .examUnlockFailed: "exam_unlock_failed"
        case .examSubmitted: "exam_submit"
        case .examSubmitFailed: "exam_submit_failed"
        case .loginCodeRequested: "login_code_requested"
        case .loginSucceeded: "login_success"
        case .loginFailed: "login_failed"
        case .onboardingCompleted: "onboarding_complete"
        case .profileCompleted: "profile_completed"
        case .profileUpdated: "profile_updated"
        case .searchUsed: "search_used"
        case .signedOut: "sign_out"
        case .accountDeleted: "account_deleted"
        case .updatePromptShown: "update_prompt_shown"
        case .updateAction: "update_action"
        case .submissionApproved: "submission_approved"
        case .submissionRejected: "submission_rejected"
        }
    }

    var firebaseParameters: [String: Any]? {
        switch self {
        case let .screenView(name):
            return [AnalyticsParameterScreenName: name]
        case let .browse(level):
            return ["level": level.analyticsName]
        case let .examOpened(kind):
            return ["kind": kind.rawValue]
        case let .examUnlockSheetShown(canAfford):
            return ["can_afford": canAfford]
        case let .examUnlocked(kind, coinsSpent, alreadyUnlocked):
            return ["exam_kind": kind.rawValue, "coins_spent": coinsSpent, "already_unlocked": alreadyUnlocked]
        case let .examSubmitted(kind, fileCount, tier):
            var params: [String: Any] = ["exam_kind": kind.rawValue, "file_count": fileCount]
            if let tier { params["estimated_tier"] = tier.rawValue }
            return params
        case let .loginCodeRequested(isResend):
            return ["resend": isResend]
        case let .onboardingCompleted(method, source):
            return ["method": method, "source": source]
        case let .searchUsed(level, zeroResults):
            return ["level": level.analyticsName, "zero_results": zeroResults]
        case let .updatePromptShown(isRequired):
            return ["type": isRequired ? "required" : "optional"]
        case let .updateAction(action):
            return ["action": action]
        case let .submissionApproved(tier):
            return ["tier": tier.rawValue]
        case let .loginFailed(reason, step):
            return ["reason": reason, "step": step]
        case let .examUnlockFailed(reason), let .examSubmitFailed(reason):
            return ["reason": reason]
        case .recentExamOpened, .earnCoinsTapped, .loginSucceeded, .profileCompleted, .profileUpdated,
             .signedOut, .accountDeleted, .submissionRejected:
            return nil
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

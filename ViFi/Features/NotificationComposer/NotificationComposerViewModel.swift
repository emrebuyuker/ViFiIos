import Foundation
import Observation

/// What the confirmation dialog shows before a notification goes out: the draft exactly as it will be sent and
/// the server's exact reach for it.
nonisolated struct NotificationSendConfirmation: Equatable, Sendable {
    let draft: NotificationDraft
    let preview: NotificationPreview
}

/// Drives the admin "Bildirim Gönder" form: the draft's fields, the cascading audience pickers fed by
/// `AudienceFacets`, live validation and the reach estimate, and the send flow (preview, confirm, send).
///
/// The server re-validates everything; this only keeps the admin from sending something it would refuse. The
/// draft `id` stays the same across retries of one send (the server answers a repeat with the first result) and
/// is replaced once a send has gone through.
@Observable
final class NotificationComposerViewModel {
    /// Who the notification is for, as the form offers it. The server-only audiences are not selectable.
    enum AudienceMode: Hashable {
        case everyone
        case segment
    }

    /// The attachment the form offers. Exam comes with a later phase.
    enum ActionChoice: Hashable {
        case noAction
        case paywall
        case addExam
        case url
        case location
    }

    /// The kinds an admin can pick; `system` is for automatic messages only.
    static let selectableKinds: [NotificationKind] = [.general, .promo]
    /// How long a notification stays visible when the admin turns the validity on.
    private static let defaultValidity: TimeInterval = 7 * 24 * 3600
    private static let defaultScheduleLead: TimeInterval = 3600
    private static let turkish = Locale(identifier: "tr_TR")

    // MARK: Fields

    var kind: NotificationKind = .general
    var title = ""
    var body = ""
    var audienceMode: AudienceMode = .everyone
    var gender: Gender?
    var actionChoice: ActionChoice = .noAction
    var urlText = ""
    /// The place picked on the map for a location action; kept while the admin switches actions back and forth.
    var location: NotificationLocation?
    /// `nil` sends right away. Changed through `setScheduling(_:)` so it always has a sensible value.
    var scheduledAt: Date?
    var expiresAt: Date?

    private(set) var universityId: String?
    private(set) var facultyId: String?
    private(set) var departmentId: String?

    // MARK: State

    private(set) var facets: Loadable<AudienceFacets> = .loading
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private(set) var successMessage: String?
    /// The preview awaiting the admin's yes; kept until the send resolves or is declined.
    private(set) var confirmation: NotificationSendConfirmation?
    /// Whether the confirmation dialog is up. Separate from `confirmation` so dismissing the dialog (which the
    /// system does before running a button's action) does not drop what the action is about to send.
    var isConfirming = false

    /// The id of the draft being composed.
    private(set) var draftId = NotificationComposerViewModel.makeId()

    @ObservationIgnored private let service: any NotificationAdminServicing
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var hasLoadedFacets = false

    init(service: any NotificationAdminServicing, now: @escaping () -> Date = { .now }) {
        self.service = service
        self.now = now
    }

    // MARK: - Audience facets

    /// Loads the picker data once per screen; a cancelled load is retried on reappearance.
    func loadFacetsIfNeeded() async {
        guard !hasLoadedFacets else { return }
        hasLoadedFacets = true
        await loadFacets()
    }

    func reloadFacets() async {
        await loadFacets()
    }

    /// Universities that have registered users, by name.
    var universities: [AudienceNode] {
        Self.sorted(facets.value?.universities ?? [])
    }

    var faculties: [AudienceNode] {
        guard let universityId else { return [] }
        return Self.sorted(facets.value?.faculties(ofUniversity: universityId) ?? [])
    }

    var departments: [AudienceNode] {
        guard let universityId, let facultyId else { return [] }
        return Self.sorted(facets.value?.departments(ofUniversity: universityId, faculty: facultyId) ?? [])
    }

    /// Changing a level resets the levels below it, so the selection never mixes values from different branches.
    func selectUniversity(_ id: String?) {
        guard id != universityId else { return }
        universityId = id
        facultyId = nil
        departmentId = nil
    }

    func selectFaculty(_ id: String?) {
        guard id != facultyId else { return }
        facultyId = id
        departmentId = nil
    }

    func selectDepartment(_ id: String?) {
        // A department is only meaningful under a faculty.
        departmentId = facultyId == nil ? nil : id
    }

    /// The users the current audience reaches according to the registered profiles, or `nil` while unknown.
    /// Campaigns are narrowed further to users who opted in; only the preview knows that number.
    var estimatedRecipients: Int? {
        guard let facets = facets.value else { return nil }
        switch audienceMode {
        case .everyone:
            return facets.total
        case .segment:
            return segment.map { facets.estimatedRecipients(for: $0) }
        }
    }

    // MARK: - Draft

    /// The draft as the form currently stands (a link that does not parse is left out; `issue` reports it).
    var draft: NotificationDraft {
        var draft = NotificationDraft()
        draft.id = draftId
        draft.kind = kind
        draft.title = title
        draft.body = body
        draft.audience = audience
        draft.action = action
        draft.scheduledAt = scheduledAt
        draft.expiresAt = expiresAt
        return draft
    }

    /// The first problem that blocks sending, or `nil` when the form is ready.
    var issue: NotificationDraft.Issue? {
        issue(of: draft)
    }

    /// The issue worth showing now: an empty title or message is not flagged before the admin has typed anything.
    var visibleIssue: NotificationDraft.Issue? {
        switch issue {
        case .emptyTitle? where title.isEmpty, .emptyBody? where body.isEmpty:
            nil
        case let issue:
            issue
        }
    }

    var canSend: Bool {
        !isWorking && issue == nil
    }

    var canSendTest: Bool {
        !isWorking && issue(of: testDraft(id: draftId)) == nil
    }

    var titleLength: Int { draft.trimmedTitle.count }
    var bodyLength: Int { draft.trimmedBody.count }

    // MARK: - Timing

    /// Turns the delayed send on (an hour from now) or off.
    func setScheduling(_ isOn: Bool) {
        scheduledAt = isOn ? now().addingTimeInterval(Self.defaultScheduleLead) : nil
        // A validity set against the old time would otherwise end up before the new delivery.
        if isOn, let expiresAt, expiresAt <= (scheduledAt ?? now()) {
            self.expiresAt = (scheduledAt ?? now()).addingTimeInterval(Self.defaultValidity)
        }
    }

    /// Turns the validity period on (a week after delivery) or off.
    func setExpiry(_ isOn: Bool) {
        expiresAt = isOn ? (scheduledAt ?? now()).addingTimeInterval(Self.defaultValidity) : nil
    }

    // MARK: - Sending

    /// Asks the server for the exact reach and raises the confirmation dialog; nothing is sent yet.
    func requestSend() async {
        guard canSend else { return }
        let draft = draft
        beginWork()
        defer { isWorking = false }
        do {
            let preview = try await service.preview(kind: draft.effectiveKind, audience: draft.audience)
            confirmation = NotificationSendConfirmation(draft: draft, preview: preview)
            isConfirming = true
        } catch is CancellationError {
            // The screen went away; nothing to report.
        } catch {
            errorMessage = error.userMessage
        }
    }

    /// Sends the draft the admin confirmed. Success resets the form for the next notification; a failure keeps
    /// it (and the draft id) so the same send can be retried.
    func confirmSend() async {
        guard !isWorking, let confirmation else { return }
        beginWork()
        defer { isWorking = false }
        do {
            let result = try await service.send(confirmation.draft)
            self.confirmation = nil
            handle(result)
        } catch is CancellationError {
            self.confirmation = nil
        } catch {
            self.confirmation = nil
            errorMessage = error.userMessage
        }
    }

    func cancelConfirmation() {
        isConfirming = false
        confirmation = nil
    }

    /// Sends the notification to the admin only, under a fresh id so the real one is not used up.
    func sendTest() async {
        guard !isWorking else { return }
        let draft = testDraft(id: Self.makeId())
        guard issue(of: draft) == nil else { return }
        beginWork()
        defer { isWorking = false }
        do {
            _ = try await service.send(draft)
            successMessage = String(localized: "Test bildirimi gönderildi. Birazdan cihazına ulaşır.")
        } catch is CancellationError {
            // The screen went away; nothing to report.
        } catch {
            errorMessage = error.userMessage
        }
    }

    // MARK: - Private

    private var segment: NotificationSegment? {
        guard let universityId, !universityId.isEmpty else { return nil }
        return NotificationSegment(universityId: universityId, facultyId: facultyId, departmentId: departmentId, gender: gender)
    }

    private var audience: NotificationAudience {
        switch audienceMode {
        case .everyone:
            .all
        case .segment:
            // Without a university the draft reports an invalid audience instead of silently going to everyone.
            .segment(segment ?? NotificationSegment(universityId: "", facultyId: nil, departmentId: nil, gender: gender))
        }
    }

    private var parsedURL: URL? {
        let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : URL(string: text)
    }

    private var action: NotificationDraft.Action? {
        switch actionChoice {
        case .noAction: nil
        case .paywall: .paywall
        case .addExam: .addExam
        case .url: parsedURL.map(NotificationDraft.Action.url)
        case .location: location.map(NotificationDraft.Action.location)
        }
    }

    private func issue(of draft: NotificationDraft) -> NotificationDraft.Issue? {
        if let issue = draft.validationIssue(now: now()) { return issue }
        // A link that did not parse, or a place not picked yet, left the draft without an action; do not send it
        // as if none was chosen.
        switch actionChoice {
        case .url where draft.action == nil: return .invalidURL
        case .location where draft.action == nil: return .invalidLocation
        default: return nil
        }
    }

    /// The test copy: addressed to the admin only, so it goes out at once with no validity, and an unfinished
    /// segment (which a test does not need) falls back to everyone rather than blocking the test.
    private func testDraft(id: String) -> NotificationDraft {
        var test = draft
        test.id = id
        test.isTest = true
        test.scheduledAt = nil
        test.expiresAt = nil
        if test.validationIssue(now: now()) == .invalidAudience {
            test.audience = .all
        }
        return test
    }

    private func beginWork() {
        isWorking = true
        errorMessage = nil
        successMessage = nil
    }

    private func handle(_ result: NotificationSendResult) {
        switch result.status {
        case .sent, .sending:
            successMessage = String(localized: "Bildirim gönderildi. Alıcı sayısı: \(result.recipients).")
            resetDraft()
        case .scheduled:
            if let date = result.scheduledAt {
                let time = date.formatted(date: .abbreviated, time: .shortened)
                successMessage = String(localized: "Bildirim \(time) için zamanlandı. Alıcı sayısı: \(result.recipients).")
            } else {
                successMessage = String(localized: "Bildirim zamanlandı. Alıcı sayısı: \(result.recipients).")
            }
            resetDraft()
        case .failed, .canceled:
            // The server kept that id as a failed record; a retry has to be a new notification.
            errorMessage = String(localized: "Bildirim gönderilemedi. Ayrıntı için geçmişe bak.")
            draftId = Self.makeId()
        }
    }

    /// Back to an empty form for the next notification, with a new id. The loaded facets are kept.
    private func resetDraft() {
        draftId = Self.makeId()
        kind = .general
        title = ""
        body = ""
        audienceMode = .everyone
        universityId = nil
        facultyId = nil
        departmentId = nil
        gender = nil
        actionChoice = .noAction
        urlText = ""
        location = nil
        scheduledAt = nil
        expiresAt = nil
    }

    private func loadFacets() async {
        if facets.value == nil {
            facets = .loading
        }
        do {
            facets = .loaded(try await service.audience())
        } catch is CancellationError {
            hasLoadedFacets = false
        } catch {
            facets = .failed(message: error.userMessage)
        }
    }

    private static func makeId() -> String {
        UUID().uuidString.lowercased()
    }

    /// By name, Turkish collation (so İ, Ş, Ç sort where a Turkish reader expects them).
    private static func sorted(_ nodes: [AudienceNode]) -> [AudienceNode] {
        nodes.sorted { $0.name.compare($1.name, locale: turkish) == .orderedAscending }
    }
}

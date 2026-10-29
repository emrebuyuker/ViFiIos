import Foundation
import Testing
@testable import ViFi

/// A reporter the test controls: records every report, can be made to fail, and can hold reports at a gate.
final class SpyNotificationEventReporter: NotificationEventReporting {
    struct Report: Equatable {
        let event: NotificationEvent
        let notificationId: String
    }

    /// Fails every report with it when set.
    var error: (any Error)?
    var gate: AsyncGate?
    private(set) var reports: [Report] = []

    func report(_ event: NotificationEvent, notificationId: String) async throws {
        reports.append(Report(event: event, notificationId: notificationId))
        await gate?.pass()
        if let error {
            throw error
        }
    }
}

/// Reporting opened / acted-on notifications: once per user and device, in the background, failures never surface.
@MainActor
@Suite("NotificationEventTracker", .timeLimit(.minutes(1)))
struct NotificationEventTrackerTests {
    private let reporter = SpyNotificationEventReporter()
    private let storage: TemporaryDefaults

    init() throws {
        storage = try TemporaryDefaults()
    }

    private func makeTracker() -> NotificationEventTracker {
        NotificationEventTracker(reporter: reporter, defaults: storage.defaults)
    }

    private enum ReportError: Error {
        case offline
    }

    @Test("A report is sent with its event and notification id")
    func sendsTheReport() async {
        let tracker = makeTracker()

        await tracker.report(.opened, notificationId: "n-1", uid: "alice")?.value
        await tracker.report(.actionTapped, notificationId: "n-1", uid: "alice")?.value

        #expect(reporter.reports == [
            .init(event: .opened, notificationId: "n-1"),
            .init(event: .actionTapped, notificationId: "n-1"),
        ])
    }

    @Test("An acknowledged report is not sent again, however often it is asked for")
    func onceAcknowledged() async {
        let tracker = makeTracker()

        await tracker.report(.opened, notificationId: "n-1", uid: "alice")?.value
        let again = tracker.report(.opened, notificationId: "n-1", uid: "alice")
        let andAgain = tracker.report(.opened, notificationId: "n-1", uid: "alice")

        #expect(again == nil)
        #expect(andAgain == nil)
        #expect(reporter.reports.count == 1)
    }

    @Test("Other notifications and the other event are still reported")
    func independentKeys() async {
        let tracker = makeTracker()

        await tracker.report(.opened, notificationId: "n-1", uid: "alice")?.value
        await tracker.report(.opened, notificationId: "n-2", uid: "alice")?.value
        await tracker.report(.actionTapped, notificationId: "n-1", uid: "alice")?.value

        #expect(reporter.reports.count == 3)
    }

    @Test("A second account on the same device is reported for the same notification")
    func perUser() async {
        let tracker = makeTracker()

        await tracker.report(.opened, notificationId: "broadcast-1", uid: "alice")?.value
        await tracker.report(.opened, notificationId: "broadcast-1", uid: "bob")?.value
        let again = tracker.report(.opened, notificationId: "broadcast-1", uid: "bob")

        #expect(reporter.reports.count == 2)
        #expect(again == nil)
    }

    @Test("What was reported is remembered across launches")
    func rememberedOnDisk() async {
        await makeTracker().report(.opened, notificationId: "n-1", uid: "alice")?.value

        let relaunched = makeTracker()
        let again = relaunched.report(.opened, notificationId: "n-1", uid: "alice")

        #expect(again == nil)
        #expect(reporter.reports.count == 1)
    }

    @Test("A failed report is only logged: nothing is remembered, so the next try sends it again")
    func failureIsRetriedNextTime() async {
        let tracker = makeTracker()
        reporter.error = ReportError.offline

        await tracker.report(.opened, notificationId: "n-1", uid: "alice")?.value
        #expect(reporter.reports.count == 1)

        reporter.error = nil
        await tracker.report(.opened, notificationId: "n-1", uid: "alice")?.value
        #expect(reporter.reports.count == 2)

        let acknowledged = tracker.report(.opened, notificationId: "n-1", uid: "alice")
        #expect(acknowledged == nil)
    }

    @Test("It returns at once: the report runs in the background and a repeat while it is in flight is dropped")
    func doesNotBlockAndDropsRepeatsInFlight() async {
        let tracker = makeTracker()
        let gate = AsyncGate()
        reporter.gate = gate

        let first = tracker.report(.actionTapped, notificationId: "n-1", uid: "alice")
        // Nothing has been answered yet; the caller already has its control back.
        await gate.waitForArrival()
        let repeated = tracker.report(.actionTapped, notificationId: "n-1", uid: "alice")
        #expect(repeated == nil)

        gate.open()
        await first?.value
        #expect(reporter.reports.count == 1)
    }

    @Test("A report that failed in flight can be sent again afterwards")
    func inFlightMarkIsReleasedOnFailure() async {
        let tracker = makeTracker()
        reporter.error = ReportError.offline

        await tracker.report(.opened, notificationId: "n-1", uid: "alice")?.value
        let retry = tracker.report(.opened, notificationId: "n-1", uid: "alice")

        #expect(retry != nil)
        await retry?.value
    }

    @Test("The memory keeps only the newest entries")
    func memoryIsBounded() async {
        let tracker = makeTracker()
        let overflow = 5

        for index in 0..<(NotificationEventTracker.capacity + overflow) {
            await tracker.report(.opened, notificationId: "n-\(index)", uid: "alice")?.value
        }

        let stored = storage.defaults.stringArray(forKey: NotificationEventTracker.defaultsKey) ?? []
        #expect(stored.count == NotificationEventTracker.capacity)
        // The oldest were forgotten (and would be sent again), the newest are still remembered.
        #expect(tracker.report(.opened, notificationId: "n-0", uid: "alice") != nil)
        #expect(tracker.report(.opened, notificationId: "n-\(NotificationEventTracker.capacity + overflow - 1)", uid: "alice") == nil)
    }

    @Test("The no-op reporter accepts everything and sends nothing")
    func noopReporter() async throws {
        let reporter = NoopNotificationEventReporter()
        try await reporter.report(.opened, notificationId: "n-1")
        try await reporter.report(.actionTapped, notificationId: "n-1")
    }

    @Test("The events are named as the callable expects")
    func eventNames() {
        #expect(NotificationEvent.opened.rawValue == "opened")
        #expect(NotificationEvent.actionTapped.rawValue == "actionTapped")
        #expect(NotificationEvent.allCases.count == 2)
    }
}

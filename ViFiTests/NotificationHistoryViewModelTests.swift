import Foundation
import Testing
@testable import ViFi

@MainActor
@Suite("NotificationHistoryViewModel")
struct NotificationHistoryViewModelTests {
    private func row(_ id: String, status: NotificationStatus = .sent) -> SentNotification {
        SentNotification(
            id: id,
            kind: .general,
            title: "Başlık \(id)",
            body: "Mesaj",
            audience: .all,
            audienceLabel: "Tüm kullanıcılar",
            status: status,
            isTest: false,
            isAutomatic: false,
            deferredByQuietHours: false,
            createdAt: Date(timeIntervalSince1970: 1_761_000_000),
            scheduledAt: status == .scheduled ? Date(timeIntervalSince1970: 1_761_100_000) : nil,
            sentAt: nil,
            stats: .zero
        )
    }

    @Test("Loading lists the history once")
    func loads() async {
        let service = StubNotificationAdminService()
        service.historyResult = .success([row("a"), row("b")])
        let viewModel = NotificationHistoryViewModel(service: service)

        await viewModel.loadIfNeeded()

        #expect(viewModel.state.value?.map(\.id) == ["a", "b"])

        service.historyResult = .success([row("c")])
        await viewModel.loadIfNeeded()
        #expect(viewModel.state.value?.map(\.id) == ["a", "b"], "loadIfNeeded does not reload")

        await viewModel.refresh()
        #expect(viewModel.state.value?.map(\.id) == ["c"])
    }

    @Test("A failed load shows an error, and a failed refresh keeps the rows")
    func failures() async {
        let service = StubNotificationAdminService()
        service.historyResult = .failure(NotificationAdminError.permissionDenied)
        let viewModel = NotificationHistoryViewModel(service: service)

        await viewModel.loadIfNeeded()
        if case let .failed(message) = viewModel.state {
            #expect(message == NotificationAdminError.permissionDenied.userMessage)
        } else {
            Issue.record("Expected the failed state")
        }

        service.historyResult = .success([row("a")])
        await viewModel.refresh()
        #expect(viewModel.state.value?.map(\.id) == ["a"])

        service.historyResult = .failure(NotificationAdminError.offline)
        await viewModel.refresh()
        #expect(viewModel.state.value?.map(\.id) == ["a"], "The rows stay on screen")
        #expect(viewModel.errorMessage == NotificationAdminError.offline.userMessage)
    }

    @Test("Canceling a scheduled notification calls the service and reloads")
    func cancelsScheduled() async {
        let service = StubNotificationAdminService()
        service.historyResult = .success([row("a", status: .scheduled)])
        let viewModel = NotificationHistoryViewModel(service: service)
        await viewModel.loadIfNeeded()

        service.historyResult = .success([row("a", status: .canceled)])
        await viewModel.cancel(row("a", status: .scheduled))

        #expect(service.canceledIDs == ["a"])
        #expect(viewModel.state.value?.first?.status == .canceled)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.cancelingId == nil)
    }

    @Test("Only a scheduled notification can be canceled")
    func ignoresOthers() async {
        let service = StubNotificationAdminService()
        let viewModel = NotificationHistoryViewModel(service: service)

        await viewModel.cancel(row("a", status: .sent))
        await viewModel.cancel(row("b", status: .canceled))

        #expect(service.canceledIDs.isEmpty)
    }

    @Test("A failed cancellation reports the error and leaves the list alone")
    func cancelFailure() async {
        let service = StubNotificationAdminService()
        service.historyResult = .success([row("a", status: .scheduled)])
        service.cancelError = NotificationAdminError.offline
        let viewModel = NotificationHistoryViewModel(service: service)
        await viewModel.loadIfNeeded()

        await viewModel.cancel(row("a", status: .scheduled))

        #expect(viewModel.errorMessage == NotificationAdminError.offline.userMessage)
        #expect(viewModel.state.value?.first?.status == .scheduled)
        #expect(viewModel.cancelingId == nil)
    }

    @Test("Canceling one that already went out reloads to show where it is")
    func notCancelableReloads() async {
        let service = StubNotificationAdminService()
        service.historyResult = .success([row("a", status: .scheduled)])
        service.cancelError = NotificationAdminError.notCancelable
        let viewModel = NotificationHistoryViewModel(service: service)
        await viewModel.loadIfNeeded()

        service.historyResult = .success([row("a", status: .sent)])
        await viewModel.cancel(row("a", status: .scheduled))

        #expect(viewModel.errorMessage == NotificationAdminError.notCancelable.userMessage)
        #expect(viewModel.state.value?.first?.status == .sent)
    }

    @Test("A second cancellation while one is in flight is ignored")
    func cancelInFlight() async {
        let gate = AsyncGate()
        let service = StubNotificationAdminService()
        service.historyResult = .success([row("a", status: .scheduled), row("b", status: .scheduled)])
        let viewModel = NotificationHistoryViewModel(service: service)
        await viewModel.loadIfNeeded()

        service.gate = gate
        let first = Task { await viewModel.cancel(row("a", status: .scheduled)) }
        await gate.waitForArrival()
        #expect(viewModel.cancelingId == "a")

        await viewModel.cancel(row("b", status: .scheduled))
        #expect(service.canceledIDs == ["a"])

        gate.open()
        await first.value
        #expect(viewModel.cancelingId == nil)
    }
}

import Foundation
import Testing
@testable import ViFi

@Suite("NotificationRouter")
struct NotificationRouterTests {
    @Test("A tapped push only leaves a pending request: nothing opens before the gates are passed")
    func receiveOnlyQueues() {
        let router = NotificationRouter()

        router.receive(notificationId: "n-1")

        #expect(router.pending == NotificationRouter.Request(notificationId: "n-1"))
        #expect(!router.isInboxPresented)
        #expect(router.highlightedId == nil)
    }

    @Test("Delivering opens the inbox on the notification and clears the request")
    func deliverOpensAndHighlights() {
        let router = NotificationRouter()
        router.receive(notificationId: "n-1")

        router.deliverPending()

        #expect(router.isInboxPresented)
        #expect(router.highlightedId == "n-1")
        #expect(router.pending == nil)
    }

    @Test("A push without a notification id still opens the inbox, with nothing highlighted")
    func pushWithoutId() {
        let router = NotificationRouter()
        router.receive(notificationId: nil)

        router.deliverPending()

        #expect(router.isInboxPresented)
        #expect(router.highlightedId == nil)
    }

    @Test("Delivering with nothing pending does nothing")
    func deliverWithoutPending() {
        let router = NotificationRouter()

        router.deliverPending()

        #expect(!router.isInboxPresented)
    }

    @Test("A request waits until it is delivered, and a newer tap replaces it")
    func newerTapReplaces() {
        let router = NotificationRouter()
        router.receive(notificationId: "first")
        router.receive(notificationId: "second")

        router.deliverPending()

        #expect(router.highlightedId == "second")
    }

    @Test("A tap while the inbox is already open moves the highlight")
    func tapWhileOpen() {
        let router = NotificationRouter()
        router.openInbox()
        router.receive(notificationId: "n-2")

        router.deliverPending()

        #expect(router.isInboxPresented)
        #expect(router.highlightedId == "n-2")
    }

    @Test("The bell opens the inbox without a highlight, and closing it clears the highlight")
    func bellAndDismiss() {
        let router = NotificationRouter()
        router.receive(notificationId: "n-1")
        router.deliverPending()
        router.isInboxPresented = false
        router.inboxDidDismiss()

        router.openInbox()

        #expect(router.isInboxPresented)
        #expect(router.highlightedId == nil)
    }

    @Test("Signing out drops a pending tap, a highlight and an open inbox")
    func resetDropsEverything() {
        let router = NotificationRouter()
        router.receive(notificationId: "pending")
        router.openInbox()

        router.reset()

        #expect(router.pending == nil)
        #expect(router.highlightedId == nil)
        #expect(!router.isInboxPresented)
    }

    @Test("The id of a tapped push comes from its payload; anything unsafe or missing is no id")
    func tapPayload() {
        #expect(NotificationPayloadParser.notificationId(fromPush: ["notificationId": "abc-123", "kind": "general"]) == "abc-123")
        #expect(NotificationPayloadParser.notificationId(fromPush: ["kind": "general"]) == nil)
        #expect(NotificationPayloadParser.notificationId(fromPush: ["notificationId": "../x"]) == nil)
    }
}

@Suite("Inbox action button")
struct InboxActionButtonTests {
    @Test("Every action the app can offer has a button; a place does not yet")
    func buttons() throws {
        let target = NotificationExamTarget(examId: "e", path: Fixture.pdfExam, kind: .pdf)
        let place = NotificationLocation(latitude: 41, longitude: 29, name: "Kampüs", address: nil, placeId: nil)

        #expect(NotificationAction.exam(target).inboxButton?.title == "Sınava Git")
        #expect(NotificationAction.paywall.inboxButton?.title == "Premium'a Göz At")
        #expect(NotificationAction.addExam.inboxButton?.title == "Sınav Ekle")
        let link = try #require(URL(string: "https://example.com/duyuru"))
        #expect(NotificationAction.url(link).inboxButton?.title == "Bağlantıyı Aç")
        #expect(NotificationAction.location(place).inboxButton == nil)
    }
}

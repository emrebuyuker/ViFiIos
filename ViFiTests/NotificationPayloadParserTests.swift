import Foundation
import Testing
@testable import ViFi

@Suite("NotificationPayloadParser")
struct NotificationPayloadParserTests {
    private let created = Date(timeIntervalSince1970: 1_761_700_000)

    // MARK: Inbox

    @Test("A full inbox document parses with its action, image and dates")
    func fullInboxItem() throws {
        let data: [String: Any] = [
            "kind": "promo",
            "title": "  Kampüs kafede %20 indirim ",
            "body": "Öğrenci kartını göster.",
            "image": ["storagePath": "notificationImages/n-1.jpg"],
            "action": ["type": "location", "latitude": 41.0848, "longitude": 29.0510, "name": "Kampüs Kafe"],
            "createdAt": created,
            "expiresAt": 1_761_800_000_000,
        ]

        let item = try #require(NotificationPayloadParser.inboxItem(id: "n-1", source: .personal, data: data))

        #expect(item.kind == .promo)
        #expect(item.title == "Kampüs kafede %20 indirim")
        #expect(item.imageStoragePath == "notificationImages/n-1.jpg")
        #expect(item.createdAt == created)
        #expect(item.expiresAt == Date(timeIntervalSince1970: 1_761_800_000))
        guard case let .location(location) = item.action else {
            Issue.record("Expected a location action")
            return
        }
        #expect(location.name == "Kampüs Kafe")
        #expect(location.latitude == 41.0848)
    }

    @Test("A legacy announcement (title/body/createdAt only) still parses as a general broadcast")
    func legacyAnnouncement() throws {
        let data: [String: Any] = ["title": "Hoş geldin", "body": "Merhaba", "createdAt": created]

        let item = try #require(NotificationPayloadParser.inboxItem(id: "AbC123xyz", source: .broadcast, data: data))

        #expect(item.kind == .general)
        #expect(item.action == nil)
        #expect(item.imageStoragePath == nil)
        #expect(item.expiresAt == nil)
    }

    @Test("An image is read only as a notification image path; URLs and other paths are ignored")
    func imageStoragePath() {
        let valid: [String: Any] = ["storagePath": " notificationImages/3f2b8c1e-0d7a-4b8e-9f3a-333333333333.jpg "]
        #expect(NotificationPayloadParser.imageStoragePath(from: valid) == "notificationImages/3f2b8c1e-0d7a-4b8e-9f3a-333333333333.jpg")
        let invalid: [Any?] = [
            nil,
            "notificationImages/x.jpg",
            ["url": "https://storage.googleapis.com/b/notificationImages/x.jpg"],
            ["storagePath": "imagess/x.jpg"],
            ["storagePath": "notificationImages/x.png"],
            ["storagePath": "notificationImages/../imagess/x.jpg"],
            ["storagePath": "notificationImages/a/b.jpg"],
            ["storagePath": "notificationImages/.jpg"],
            ["storagePath": "notificationImages/\(String(repeating: "a", count: 129)).jpg"],
            ["storagePath": 42],
        ]
        for value in invalid {
            #expect(NotificationPayloadParser.imageStoragePath(from: value) == nil, "\(String(describing: value))")
        }
        #expect(NotificationImage.storagePath(forNotificationId: "abc") == "notificationImages/abc.jpg")
        #expect(NotificationImage.isValidStoragePath("notificationImages/\(String(repeating: "a", count: 128)).jpg"))
    }

    @Test("A document without a title, or with an unsafe id, is dropped")
    func requiresTitleAndSafeId() {
        #expect(NotificationPayloadParser.inboxItem(id: "n-1", source: .broadcast, data: ["title": "  "]) == nil)
        #expect(NotificationPayloadParser.inboxItem(id: "a/b", source: .broadcast, data: ["title": "x"]) == nil)
        #expect(NotificationPayloadParser.inboxItem(id: "", source: .broadcast, data: ["title": "x"]) == nil)
    }

    @Test("An unknown kind reads as general and an unknown action is dropped, keeping the entry")
    func toleratesNewerServer() throws {
        let data: [String: Any] = ["title": "x", "kind": "survey", "action": ["type": "poll"]]

        let item = try #require(NotificationPayloadParser.inboxItem(id: "n-1", source: .personal, data: data))

        #expect(item.kind == .general)
        #expect(item.action == nil)
    }

    @Test("Actions: exam needs a full path ending in the exam id; url must be https")
    func actions() throws {
        let examData: [String: Any] = [
            "type": "exam",
            "examId": "u__f__d__c__vize",
            "path": ["u", "u__f", "u__f__d", "u__f__d__c", "u__f__d__c__vize"],
            "names": ["Üniv", "Fakülte", "Bölüm", "Ders", "Vize"],
            "examKind": "PDF",
        ]
        guard case let .exam(target) = try #require(NotificationPayloadParser.action(from: examData)) else {
            Issue.record("Expected an exam action")
            return
        }
        #expect(target.kind == .pdf)
        #expect(target.path.displayNames.last == "Vize")

        var shortPath = examData
        shortPath["path"] = ["u", "u__f__d__c__vize"]
        #expect(NotificationPayloadParser.action(from: shortPath) == nil)

        #expect(NotificationPayloadParser.action(from: ["type": "url", "url": "http://example.com"]) == nil)
        #expect(NotificationPayloadParser.action(from: ["type": "url", "url": "https://example.com/a"]) != nil)
        #expect(NotificationPayloadParser.action(from: ["type": "paywall"]) == .paywall)
        #expect(NotificationPayloadParser.action(from: ["type": "addExam"]) == .addExam)
    }

    @Test("A location outside the valid range, or with a flag for a coordinate, is rejected")
    func invalidLocation() {
        let outOfRange: [String: Any] = ["type": "location", "latitude": 95.0, "longitude": 29.0, "name": "x"]
        let flagCoordinate: [String: Any] = ["type": "location", "latitude": true, "longitude": 29.0, "name": "x"]
        #expect(NotificationPayloadParser.action(from: outOfRange) == nil)
        #expect(NotificationPayloadParser.action(from: flagCoordinate) == nil)
    }

    // MARK: Admin

    @Test("Audience facets parse into a university → faculty → department tree with counts")
    func facets() throws {
        let value: [String: Any] = [
            "total": 10,
            "universities": [[
                "id": "bogazici-universitesi", "name": "Boğaziçi Üniversitesi", "count": 10, "female": 6, "male": 4,
                "faculties": [[
                    "id": "muhendislik-fakultesi", "name": "Mühendislik Fakültesi", "count": 7, "female": 4, "male": 3,
                    "departments": [["id": "bilgisayar-muhendisligi", "name": "Bilgisayar", "count": 5, "female": 3, "male": 2]],
                ]],
            ]],
        ]

        let facets = try #require(NotificationPayloadParser.facets(from: value))

        #expect(facets.total == 10)
        #expect(facets.faculties(ofUniversity: "bogazici-universitesi").map(\.id) == ["muhendislik-fakultesi"])
        #expect(facets.departments(ofUniversity: "bogazici-universitesi", faculty: "muhendislik-fakultesi").first?.counts.female == 3)
    }

    @Test("Callable numbers arrive as NSNumber; 0 and 1 are counts, not flags")
    func nsNumberCounts() throws {
        let value: [String: Any] = ["recipients": NSNumber(value: 1), "pushTargets": NSNumber(value: 0)]

        let preview = try #require(NotificationPayloadParser.preview(from: value))

        #expect(preview.recipients == 1)
        #expect(preview.pushTargets == 0)
    }

    @Test("A send result needs a known status")
    func sendResult() throws {
        let value: [String: Any] = [
            "notificationId": "abc-123", "status": "scheduled", "scheduledAt": 1_761_717_600_000, "recipients": 5,
        ]
        let result = try #require(NotificationPayloadParser.sendResult(from: value))
        #expect(result.status == .scheduled)
        #expect(result.scheduledAt == Date(timeIntervalSince1970: 1_761_717_600))
        #expect(NotificationPayloadParser.sendResult(from: ["notificationId": "abc", "status": "queued"]) == nil)
    }

    @Test("A history row parses its segment audience, source and stats")
    func sentNotification() throws {
        let data: [String: Any] = [
            "kind": "general", "title": "Duyuru", "body": "Metin", "status": "sent", "source": "automatic",
            "audience": ["scope": "segment", "universityId": "u", "facultyId": "f", "gender": "female"],
            "audienceLabel": "Üniv › Fakülte · Kadın",
            "stats": ["recipients": 3, "opened": 2],
        ]

        let row = try #require(NotificationPayloadParser.sentNotification(id: "n-1", data: data))

        #expect(row.isAutomatic)
        #expect(row.audience == .segment(NotificationSegment(universityId: "u", facultyId: "f", departmentId: nil, gender: .female)))
        #expect(row.stats.recipients == 3)
        #expect(row.stats.opened == 2)
        #expect(row.stats.pushSent == 0)
    }

    // MARK: Push

    @Test("A tapped push yields its notification id; pushes without one (or with an unsafe one) yield nil")
    func pushNotificationId() {
        #expect(NotificationPayloadParser.notificationId(fromPush: ["notificationId": "abc-123"]) == "abc-123")
        #expect(NotificationPayloadParser.notificationId(fromPush: ["aps": ["alert": "x"]]) == nil)
        #expect(NotificationPayloadParser.notificationId(fromPush: ["notificationId": "../x"]) == nil)
    }
}

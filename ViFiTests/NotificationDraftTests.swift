import Foundation
import Testing
@testable import ViFi

@Suite("NotificationDraft")
struct NotificationDraftTests {
    private let now = Date(timeIntervalSince1970: 1_761_700_000)

    private func draft(_ configure: (inout NotificationDraft) -> Void = { _ in }) -> NotificationDraft {
        var draft = NotificationDraft()
        draft.title = "Başlık"
        draft.body = "Mesaj"
        configure(&draft)
        return draft
    }

    @Test("A titled, bodied draft to everyone is ready")
    func readyDraft() {
        #expect(draft().validationIssue(now: now) == nil)
    }

    @Test("Title and body are required and limited")
    func textLimits() {
        #expect(draft { $0.title = "   " }.validationIssue(now: now) == .emptyTitle)
        #expect(draft { $0.title = String(repeating: "a", count: 81) }.validationIssue(now: now) == .titleTooLong)
        #expect(draft { $0.body = "" }.validationIssue(now: now) == .emptyBody)
        #expect(draft { $0.body = String(repeating: "a", count: 501) }.validationIssue(now: now) == .bodyTooLong)
    }

    @Test("A segment needs a university, and a department needs its faculty")
    func segmentRules() {
        let noUniversity = NotificationSegment(universityId: "", facultyId: nil, departmentId: nil, gender: nil)
        let departmentOnly = NotificationSegment(universityId: "u", facultyId: nil, departmentId: "d", gender: nil)
        let full = NotificationSegment(universityId: "u", facultyId: "f", departmentId: "d", gender: .female)

        #expect(draft { $0.audience = .segment(noUniversity) }.validationIssue(now: now) == .invalidAudience)
        #expect(draft { $0.audience = .segment(departmentOnly) }.validationIssue(now: now) == .invalidAudience)
        #expect(draft { $0.audience = .segment(full) }.validationIssue(now: now) == nil)
    }

    @Test("The composer cannot address a single user or the admins")
    func serverOnlyAudiences() {
        #expect(draft { $0.audience = .user(uid: "x") }.validationIssue(now: now) == .invalidAudience)
        #expect(draft { $0.audience = .admins }.validationIssue(now: now) == .invalidAudience)
    }

    @Test("A location makes the notification a campaign, whatever kind was picked")
    func locationIsPromo() {
        let location = NotificationLocation(latitude: 41, longitude: 29, name: "Kafe", address: nil, placeId: nil)
        let located = draft {
            $0.kind = .general
            $0.action = .location(location)
        }

        #expect(located.effectiveKind == .promo)
        #expect(located.payload["kind"] as? String == "promo")
    }

    @Test("Actions are validated: location range, https links, a picked exam")
    func actionValidation() throws {
        let badLocation = NotificationLocation(latitude: 120, longitude: 29, name: "x", address: nil, placeId: nil)
        let httpURL = try #require(URL(string: "http://example.com"))
        #expect(draft { $0.action = .location(badLocation) }.validationIssue(now: now) == .invalidLocation)
        #expect(draft { $0.action = .url(httpURL) }.validationIssue(now: now) == .invalidURL)
        #expect(draft { $0.action = .exam(examId: " ") }.validationIssue(now: now) == .emptyExam)
    }

    @Test("Schedule and expiry: not in the past, expiry after delivery")
    func scheduleRules() {
        #expect(draft { $0.scheduledAt = now.addingTimeInterval(-3600) }.validationIssue(now: now) == .scheduleInPast)
        // Within the minute of grace.
        #expect(draft { $0.scheduledAt = now.addingTimeInterval(-30) }.validationIssue(now: now) == nil)
        #expect(draft { $0.expiresAt = now }.validationIssue(now: now) == .expiryBeforeDelivery)
        #expect(draft {
            $0.scheduledAt = now.addingTimeInterval(7200)
            $0.expiresAt = now.addingTimeInterval(3600)
        }.validationIssue(now: now) == .expiryBeforeDelivery)
    }

    @Test("The payload carries trimmed text, the segment, the action and epoch-millisecond dates")
    func payload() throws {
        let segment = NotificationSegment(universityId: "u", facultyId: "f", departmentId: nil, gender: .male)
        let value = draft {
            $0.id = "abc-123"
            $0.title = "  Başlık  "
            $0.audience = .segment(segment)
            $0.action = .exam(examId: "u__f__d__c__vize")
            $0.scheduledAt = Date(timeIntervalSince1970: 1_761_717_600)
            $0.isTest = true
        }.payload

        #expect(value["notificationId"] as? String == "abc-123")
        #expect(value["title"] as? String == "Başlık")
        #expect(value["isTest"] as? Bool == true)
        #expect(value["scheduledAt"] as? Int64 == 1_761_717_600_000)
        #expect(value["expiresAt"] == nil)
        let audience = try #require(value["audience"] as? [String: Any])
        #expect(audience["scope"] as? String == "segment")
        #expect(audience["facultyId"] as? String == "f")
        #expect(audience["departmentId"] == nil)
        #expect(audience["gender"] as? String == "male")
        let action = try #require(value["action"] as? [String: Any])
        #expect(action["type"] as? String == "exam")
        #expect(action["examId"] as? String == "u__f__d__c__vize")
    }

    @Test("Facet estimates follow the most specific level picked and the gender")
    func estimates() {
        let facets = AudienceFacets(total: 10, universities: [
            AudienceNode(id: "u", name: "Üniv", counts: AudienceCounts(total: 10, female: 6, male: 4), children: [
                AudienceNode(id: "f", name: "Fak", counts: AudienceCounts(total: 7, female: 4, male: 3), children: [
                    AudienceNode(id: "d", name: "Böl", counts: AudienceCounts(total: 5, female: 3, male: 2), children: []),
                ]),
            ]),
        ])

        #expect(facets.estimatedRecipients(for: .init(universityId: "u", facultyId: nil, departmentId: nil, gender: nil)) == 10)
        #expect(facets.estimatedRecipients(for: .init(universityId: "u", facultyId: "f", departmentId: nil, gender: .male)) == 3)
        #expect(facets.estimatedRecipients(for: .init(universityId: "u", facultyId: "f", departmentId: "d", gender: .female)) == 3)
        #expect(facets.estimatedRecipients(for: .init(universityId: "x", facultyId: nil, departmentId: nil, gender: nil)) == 0)
    }
}

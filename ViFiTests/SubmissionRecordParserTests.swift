import Foundation
import Testing
@testable import ViFi

@Suite("SubmissionRecordParser")
struct SubmissionRecordParserTests {
    private func validData(_ overrides: [String: Any] = [:]) -> [String: Any] {
        var data: [String: Any] = [
            "ownerId": "user-1",
            "university": "Boğaziçi Üniversitesi",
            "faculty": "Mühendislik Fakültesi",
            "department": "Bilgisayar Mühendisliği",
            "lesson": "Ayrık Matematik",
            "exam": "2023 VİZE",
            "kind": "JPG",
            "status": "pending",
            "files": [
                ["storagePath": "pending/user-1/s1/2.jpg", "order": 2],
                ["storagePath": "pending/user-1/s1/1.jpg", "order": 1],
            ],
        ]
        for (key, value) in overrides {
            data[key] = value
        }
        return data
    }

    @Test("A valid document is parsed, with files sorted by order")
    func parsesValid() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let record = try #require(SubmissionRecordParser.record(id: "s1", data: validData(), createdAt: date))

        #expect(record.id == "s1")
        #expect(record.ownerId == "user-1")
        #expect(record.exam == "2023 VİZE")
        #expect(record.kind == .images)
        #expect(record.status == "pending")
        #expect(record.createdAt == date)
        #expect(record.files.map(\.order) == [1, 2])
        #expect(record.files.first?.storagePath == "pending/user-1/s1/1.jpg")
    }

    @Test("A missing required field yields nil", arguments: ["ownerId", "university", "exam", "kind", "status"])
    func missingFieldIsNil(field: String) {
        var data = validData()
        data.removeValue(forKey: field)
        #expect(SubmissionRecordParser.record(id: "s1", data: data, createdAt: nil) == nil)
    }

    @Test("An unknown kind yields nil")
    func unknownKind() {
        #expect(SubmissionRecordParser.record(id: "s1", data: validData(["kind": "GIF"]), createdAt: nil) == nil)
    }

    @Test("Files without a storagePath are dropped")
    func dropsFilesWithoutPath() throws {
        let data = validData(["files": [
            ["order": 1],
            ["storagePath": "pending/user-1/s1/2.jpg", "order": 2],
        ]])
        let record = try #require(SubmissionRecordParser.record(id: "s1", data: data, createdAt: nil))
        #expect(record.files.count == 1)
        #expect(record.files.first?.storagePath == "pending/user-1/s1/2.jpg")
    }

    @Test("A record exposes its archive location")
    func exposesLocation() throws {
        let record = try #require(SubmissionRecordParser.record(id: "s1", data: validData(), createdAt: nil))
        #expect(record.location.university == "Boğaziçi Üniversitesi")
        #expect(record.location.examText == "2023 VİZE")
    }
}

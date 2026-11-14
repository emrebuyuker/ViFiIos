import Foundation
import Testing
@testable import ViFi

@Suite("Practice parsing", .timeLimit(.minutes(1)))
struct PracticeParserTests {
    private func questionData(id: String? = "e1-002", order: Int = 2, extra: [String: Any] = [:]) -> [String: Any] {
        var data: [String: Any] = [
            "examId": "e1", "order": order, "text": "Soru?", "answer": ["text": "Cevap"],
            "examTitle": "2019 FİNAL", "universityName": "Bozok Üniversitesi",
        ]
        if let id { data["id"] = id }
        return data.merging(extra) { _, new in new }
    }

    // MARK: - Index

    @Test("The index keeps practice types with positive counts per scope")
    func indexParsing() {
        let data: [String: Any] = [
            "name": "Topoloji 1",
            "types": [
                "final": ["tr": 40, "u-bozok": 12, "c-top1": 3, "c-zero": 0],
                "vize": ["tr": 1],
                "ara-sinav": ["tr": 0],
                "odev": ["tr": 9],
                "bilinmeyen": ["tr": 5],
            ] as [String: Any],
        ]

        let index = PracticeParser.index(from: data, subjectId: "topoloji-1")

        #expect(index?.subjectId == "topoloji-1")
        #expect(index?.name == "Topoloji 1")
        #expect(Set(index?.types.keys ?? [:].keys) == [.final, .vize])
        #expect(index?.types[.final] == ["tr": 40, "u-bozok": 12, "c-top1": 3])
        #expect(index?.hasPracticeQuestions == true)
    }

    @Test("An index without any usable type is no index")
    func emptyIndex() {
        #expect(PracticeParser.index(from: [:], subjectId: "s") == nil)
        #expect(PracticeParser.index(from: ["types": [String: Any]()], subjectId: "s") == nil)
        #expect(PracticeParser.index(from: ["types": ["odev": ["tr": 3]]], subjectId: "s") == nil)
    }

    @Test("Counts are looked up by scope key; an unknown university has no key")
    func countLookup() {
        let index = PracticeFixture.index(types: [.final: ["tr": 40, "u-bozok": 12, "c-top1": 3]])

        #expect(index.count(type: .final, scope: .course, courseId: "top1", universityId: nil) == 3)
        #expect(index.count(type: .final, scope: .university, courseId: "top1", universityId: "bozok") == 12)
        #expect(index.count(type: .final, scope: .university, courseId: "top1", universityId: nil) == 0)
        #expect(index.count(type: .final, scope: .turkey, courseId: "top1", universityId: nil) == 40)
        #expect(index.count(type: .vize, scope: .turkey, courseId: "top1", universityId: nil) == 0)
    }

    // MARK: - Batch

    @Test("A batch parses questions with their source and the limit fields")
    func batchParsing() {
        let data: [String: Any] = [
            "questions": [questionData(), questionData(id: "e1-003", order: 3)],
            "poolSize": 17, "remainingToday": 3, "limitReached": false,
        ]

        let batch = PracticeParser.batch(from: data)

        #expect(batch?.questions.map(\.id) == ["e1-002", "e1-003"])
        #expect(batch?.questions.first?.examTitle == "2019 FİNAL")
        #expect(batch?.questions.first?.sourceLine == "BOZOK ÜNİVERSİTESİ · 2019 FİNAL")
        #expect(batch?.poolSize == 17)
        #expect(batch?.remainingToday == 3)
        #expect(batch?.limitReached == false)
    }

    @Test("Premium has no remaining count (null)")
    func premiumBatch() {
        let data: [String: Any] = ["questions": [questionData()], "poolSize": 5, "remainingToday": NSNull(), "limitReached": false]

        #expect(PracticeParser.batch(from: data)?.remainingToday == nil)
    }

    @Test("A missing id is rebuilt from the exam id and order; an unreadable question is skipped")
    func idFallbackAndSkips() {
        let data: [String: Any] = [
            "questions": [questionData(id: nil, order: 4), ["examId": "e1", "order": 5], questionData(id: "e1-009", order: 9)],
            "poolSize": 3, "remainingToday": 0, "limitReached": true,
        ]

        let batch = PracticeParser.batch(from: data)

        #expect(batch?.questions.map(\.id) == ["e1-004", "e1-009"])
        #expect(batch?.remainingToday == 0)
        #expect(batch?.limitReached == true)
    }

    @Test("updatedAt arrives as epoch milliseconds, as a whole number or a double, or null")
    func millisecondUpdatedAt() {
        let whole = PracticeParser.question(from: questionData(extra: ["updatedAt": 1_762_000_000_000 as Int]))
        let fractional = PracticeParser.question(from: questionData(extra: ["updatedAt": 1_762_000_000_500.0 as Double]))
        let null = PracticeParser.question(from: questionData(extra: ["updatedAt": NSNull()]))

        #expect(whole?.question.updatedAt == Date(timeIntervalSince1970: 1_762_000_000))
        #expect(fractional?.question.updatedAt == Date(timeIntervalSince1970: 1_762_000_000.5))
        #expect(null != nil)
        #expect(null?.question.updatedAt == nil)
    }

    @Test("Null enrichment fields leave the source out without dropping the question")
    func nullEnrichment() {
        let question = PracticeParser.question(from: questionData(extra: ["examTitle": NSNull(), "universityName": NSNull()]))

        #expect(question?.id == "e1-002")
        #expect(question?.examTitle == nil)
        #expect(question?.universityName == nil)
        #expect(question?.sourceLine == nil)
    }

    @Test("A missing pool is an empty batch, and a limit with a re-sent question is kept as is")
    func emptyPoolAndLimit() {
        let empty = PracticeParser.batch(from: ["questions": [Any](), "poolSize": 0])
        let limited = PracticeParser.batch(from: [
            "questions": [questionData()], "poolSize": 4, "remainingToday": 0, "limitReached": true,
        ])

        #expect(empty == PracticeBatch(questions: [], poolSize: 0, remainingToday: nil, limitReached: false))
        #expect(limited?.questions.count == 1)
        #expect(limited?.limitReached == true)
    }

    @Test("A response that is not a map is rejected")
    func invalidResponse() {
        #expect(PracticeParser.batch(from: nil) == nil)
        #expect(PracticeParser.batch(from: "oops") == nil)
    }

    @Test("The source line drops what the server did not send")
    func sourceLine() {
        let question = PracticeFixture.question("e1-001")
        let bare = PracticeQuestion(question: question.question, examTitle: nil, universityName: nil)

        #expect(bare.sourceLine == nil)
        #expect(PracticeQuestion(question: question.question, examTitle: "2019 FİNAL", universityName: nil).sourceLine == "2019 FİNAL")
    }

    // MARK: - Callable payload

    @Test("The callable payload carries the scope's id, the capped exclude list and the Premium proof")
    func payload() {
        let request = PracticeRequest(
            selection: PracticeFixture.selection,
            exclude: (1...350).map { "e-\($0)" },
            count: 99
        )

        let body = FirebasePracticeService.payload(for: request, proofJWS: "jws-token")

        #expect(body["subjectId"] as? String == "topoloji-1")
        #expect(body["examType"] as? String == "final")
        #expect(body["scope"] as? String == "tr")
        #expect(body["courseId"] == nil)
        #expect(body["count"] as? Int == PracticeLimits.maxBatch)
        let exclude = body["exclude"] as? [String]
        #expect(exclude?.count == PracticeLimits.maxExclude)
        #expect(exclude?.last == "e-350")
        let proof = body["subscriptionProof"] as? [String: String]
        #expect(proof == ["platform": "ios", "jws": "jws-token"])
    }

    @Test("Course and university scopes send their ids; no proof means no proof key")
    func payloadScopes() {
        let course = PracticeSelection(
            subjectId: "s", examType: .vize, scope: .course, courseId: "c1", universityId: "u1", poolCount: 1
        )
        let university = PracticeSelection(
            subjectId: "s", examType: .vize, scope: .university, courseId: "c1", universityId: "u1", poolCount: 1
        )

        let courseBody = FirebasePracticeService.payload(for: PracticeRequest(selection: course, exclude: [], count: 1), proofJWS: nil)
        let universityBody = FirebasePracticeService.payload(
            for: PracticeRequest(selection: university, exclude: [], count: 1), proofJWS: ""
        )

        #expect(courseBody["courseId"] as? String == "c1")
        #expect(courseBody["universityId"] == nil)
        #expect(universityBody["universityId"] as? String == "u1")
        #expect(courseBody["subscriptionProof"] == nil)
        #expect(universityBody["subscriptionProof"] == nil)
    }

    // MARK: - Archive subject

    @Test("A course node's subjectId is read; blank or absent means none")
    func courseSubjectId() {
        let path = ArchivePath(components: ["u", "f", "d"])
        let docs: [(id: String, data: [String: Any])] = [
            (id: "c1", data: ["name": "Topoloji 1", "subjectId": "topoloji-1"]),
            (id: "c2", data: ["name": "Analiz", "subjectId": "  "]),
            (id: "c3", data: ["name": "Cebir"]),
        ]

        let items = FirestoreArchiveParser.items(from: docs, under: path)

        #expect(items.first { $0.name == "Topoloji 1" }?.subjectId == "topoloji-1")
        #expect(items.first { $0.name == "Analiz" }?.subjectId == nil)
        #expect(items.first { $0.name == "Cebir" }?.subjectId == nil)
    }
}

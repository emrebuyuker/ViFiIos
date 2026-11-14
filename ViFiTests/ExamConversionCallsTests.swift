import Foundation
import Testing
@testable import ViFi

@Suite("ExamConversionCalls")
struct ExamConversionCallsTests {
    @Test("Callable names match the server contract")
    func names() {
        #expect(ExamConversionCalls.Name.requestConversion == "requestExamConversion")
        #expect(ExamConversionCalls.Name.requestBulk == "requestBulkConversion")
        #expect(ExamConversionCalls.Name.regenerate == "regenerateExamConversion")
        #expect(ExamConversionCalls.Name.regenerateDraftQuestion == "regenerateDraftQuestion")
        #expect(ExamConversionCalls.Name.publish == "publishExamConversion")
        #expect(ExamConversionCalls.Name.discard == "discardExamConversion")
        #expect(ExamConversionCalls.Name.updatePublishedQuestion == "updatePublishedQuestion")
        #expect(ExamConversionCalls.Name.regeneratePublishedQuestion == "regeneratePublishedQuestion")
    }

    @Test("Request payloads carry the provider and ids as documented")
    func payloads() {
        let single = ExamConversionCalls.requestConversion(examId: "e1", provider: .claude)
        #expect(single["examId"] as? String == "e1")
        #expect(single["provider"] as? String == "claude")

        let course = ExamConversionCalls.requestBulk(scope: .course(id: "c1"), provider: .gemini, dryRun: true)
        #expect(course["courseId"] as? String == "c1")
        #expect(course["departmentId"] == nil)
        #expect(course["dryRun"] as? Bool == true)
        #expect(course["provider"] as? String == "gemini")

        let department = ExamConversionCalls.requestBulk(scope: .department(id: "d1"), provider: .claude, dryRun: false)
        #expect(department["departmentId"] as? String == "d1")
        #expect(department["dryRun"] as? Bool == false)

        let question = ExamConversionCalls.regenerateDraftQuestion(jobId: "sub-1", order: 3, provider: .gemini)
        #expect(question["jobId"] as? String == "sub-1")
        #expect(question["order"] as? Int == 3)
    }

    @Test("Publishing leaves blank subject fields and a blank title out")
    func publishPayload() {
        let blank = ExamConversionCalls.publish(jobId: "j", subjectId: "  ", newSubjectName: nil, examTitle: " ")
        #expect(blank.keys.sorted() == ["jobId"])

        let full = ExamConversionCalls.publish(jobId: "j", subjectId: "s", newSubjectName: " Yeni ", examTitle: "2019 VİZE")
        #expect(full["subjectId"] as? String == "s")
        #expect(full["newSubjectName"] as? String == "Yeni")
        #expect(full["examTitle"] as? String == "2019 VİZE")
    }

    @Test("Question content fields are the editable ones only")
    func contentFields() {
        let fields = ExamConversionCalls.contentFields(of: ConversionFixture.question())

        #expect(fields.keys.sorted() == ["answer", "choices", "solution", "speech", "text"])
        let answer = fields["answer"] as? [String: Any]
        #expect(answer?["text"] as? String == "4")
        #expect(answer?["choice"] as? String == "B")
        #expect(answer?["speech"] == nil)
        #expect((fields["choices"] as? [[String: String]])?.first == ["label": "A", "text": "3"])

        let published = ExamConversionCalls.updatePublishedQuestion(ConversionFixture.question(order: 2))
        #expect(published["questionId"] as? String == "002")
    }

    @Test("Responses are parsed leniently")
    func responses() {
        #expect(ExamConversionCalls.status(from: ["status": "queued"]) == .queued)
        #expect(ExamConversionCalls.status(from: ["status": "nope"]) == nil)
        #expect(ExamConversionCalls.jobId(from: ["jobId": "exam-1"]) == "exam-1")

        let estimate = ExamConversionCalls.bulkEstimate(from: ["examCount": 4, "estimatedCostUsd": 1.5, "jobIds": ["a", "b"]])
        #expect(estimate == BulkConversionEstimate(examCount: 4, estimatedCostUsd: 1.5, jobIds: ["a", "b"]))
        #expect(ExamConversionCalls.bulkEstimate(from: nil) == BulkConversionEstimate(examCount: 0, estimatedCostUsd: 0, jobIds: []))

        #expect(ExamConversionCalls.publishResult(from: ["examId": "e", "questionCount": 20]) == PublishedExamResult(examId: "e", questionCount: 20))
        #expect(ExamConversionCalls.publishResult(from: ["questionCount": 20]) == nil)
    }

    @Test("Monthly usage reads costUsd and treats a missing document as zero")
    func usage() {
        #expect(ExamConversionCalls.monthlyUsage(month: "2026-11", data: ["costUsd": 12.5]).costUsd == 12.5)
        #expect(ExamConversionCalls.monthlyUsage(month: "2026-11", data: nil).costUsd == 0)
        let usage = AIMonthlyUsage(month: "2026-11", costUsd: 40)
        #expect(usage.fraction == 0.8)
        #expect(usage.exceedsCap(adding: 11))
        #expect(!usage.exceedsCap(adding: 10))
    }

    @Test("The month key follows Europe/Istanbul (UTC+3)")
    func monthKey() {
        // 31 Oct 2026 22:00 UTC is already 1 Nov 01:00 in Istanbul.
        let date = Date(timeIntervalSince1970: 1_793_484_000)
        #expect(AIMonthlyUsage.monthKey(for: date) == "2026-11")
        #expect(AIMonthlyUsage.monthKey(for: date.addingTimeInterval(-4 * 3600)) == "2026-10")
    }

    @Test("Server job documents parse their files and the suggested subject")
    func parsesFilesAndSubject() {
        let job = ExamConversionParser.conversion(id: "sub-1", data: [
            "source": ["type": "submission", "submissionId": "1"],
            "kind": "JPG",
            "status": "ready",
            "files": [["storagePath": "imagess/b.jpg", "order": 2], ["storagePath": "imagess/a.jpg", "order": 1]],
            "placement": ["names": ["U"], "subjectId": "calculus", "subjectName": "Calculus"],
        ])

        #expect(job?.files.count == 2)
        #expect(job?.suggestedSubjectId == "calculus")
        #expect(job?.suggestedSubjectName == "Calculus")
    }
}

@Suite("QuestionEditDraft")
struct QuestionEditDraftTests {
    @Test("An untouched draft is valid and round-trips the question")
    func roundTrip() {
        let question = ConversionFixture.question()
        let draft = QuestionEditDraft(question: question)

        #expect(draft.isValid)
        let applied = draft.applied(to: question)
        #expect(applied.text == question.text)
        #expect(applied.choices == question.choices)
        #expect(applied.answer == question.answer)
        #expect(applied.solution == question.solution)
    }

    @Test("Empty text or answer is invalid")
    func emptyInvalid() {
        var draft = QuestionEditDraft(question: ConversionFixture.question())
        draft.text = "  "
        #expect(!draft.isValid)
        draft.text = "x"
        draft.answerText = ""
        #expect(!draft.isValid)
    }

    @Test("The answer choice must be one of the choices")
    func answerChoiceMustExist() {
        var draft = QuestionEditDraft(question: ConversionFixture.question())
        draft.answerChoice = "Z"
        #expect(!draft.isValid)
        draft.answerChoice = ""
        #expect(draft.isValid)
        #expect(draft.applied(to: ConversionFixture.question()).answer.choice == nil)
    }

    @Test("Blank choices and steps are dropped; an empty speech falls back to the text")
    func dropsBlanks() {
        var draft = QuestionEditDraft(question: ConversionFixture.question())
        draft.choices.append(.init())
        draft.solution.append(.init(text: "   "))
        draft.speech = ""

        let applied = draft.applied(to: ConversionFixture.question())

        #expect(draft.isValid)
        #expect(applied.choices.count == 2)
        #expect(applied.solution == ["2 + 2 = 4"])
        #expect(applied.speech == applied.text)
    }

    @Test("A half-filled choice is invalid")
    func halfChoice() {
        var draft = QuestionEditDraft(question: ConversionFixture.question())
        draft.choices.append(.init(label: "C", text: ""))
        #expect(!draft.isValid)
    }
}

@Suite("Publish plan serialisation")
struct PublishPlanDocumentTests {
    private let record = Fixture.submissionRecord()
    private let files = [SubmissionFileRef(storagePath: "imagess/b.jpg", order: 2), SubmissionFileRef(storagePath: "imagess/a.jpg", order: 1)]

    @Test("A new exam serialises as the documented shape")
    func shape() throws {
        let plan = ArchivePublishPlan.make(record: record, placement: ResolvedPlacement(tier: .newUniversity))

        let document = try #require(plan.publishPlanDocument(record: record, files: files))

        #expect(document.keys.sorted() == [
            "childCountIncrements", "courseId", "departmentId", "exam", "examId", "facultyId", "mode", "nodesToCreate",
            "universityId",
        ])
        #expect(document["mode"] as? String == "create")
        #expect(document["examId"] as? String == plan.examId)
        #expect(document["courseId"] as? String == plan.courseId)
        let nodes = try #require(document["nodesToCreate"] as? [[String: Any]])
        #expect(nodes.count == 4)
        #expect(nodes.allSatisfy { $0["id"] is String && $0["level"] is String && $0["parentId"] is String && $0["childCount"] is Int })
        #expect(nodes.contains { $0["source"] as? String == "submission" && $0["status"] as? String == "published" })
        #expect((document["childCountIncrements"] as? [String])?.isEmpty == true)

        let exam = try #require(document["exam"] as? [String: Any])
        #expect(exam["title"] as? String == record.exam)
        #expect(exam["source"] as? String == "submission")
        let examFiles = try #require(exam["files"] as? [[String: Any]])
        #expect(examFiles.map { $0["storagePath"] as? String } == ["imagess/a.jpg", "imagess/b.jpg"])
    }

    @Test("Existing parents are bumped, not created")
    func increments() throws {
        let placement = ResolvedPlacement(tier: .newExam, universityId: "u", facultyId: "f", departmentId: "d", courseId: "c")
        let plan = ArchivePublishPlan.make(record: record, placement: placement)

        let document = try #require(plan.publishPlanDocument(record: record, files: files))

        #expect((document["nodesToCreate"] as? [[String: Any]])?.isEmpty == true)
        #expect(document["childCountIncrements"] as? [String] == ["c"])
    }

    @Test("A duplicate serialises as a replace plan for the existing exam")
    func duplicate() throws {
        let placement = ResolvedPlacement(
            tier: .duplicate, universityId: "u", facultyId: "f", departmentId: "d", courseId: "c", examId: "c__x"
        )
        let plan = ArchivePublishPlan.make(record: record, placement: placement)

        let document = try #require(plan.publishPlanDocument(record: record, files: files))

        #expect(document["mode"] as? String == "replace")
        #expect(document["examId"] as? String == "c__x")
        #expect(document["universityId"] as? String == "u")
        #expect(document["facultyId"] as? String == "f")
        #expect(document["departmentId"] as? String == "d")
        #expect(document["courseId"] as? String == "c")
        #expect((document["nodesToCreate"] as? [[String: Any]])?.isEmpty == true)
        #expect((document["childCountIncrements"] as? [String])?.isEmpty == true)
        let exam = try #require(document["exam"] as? [String: Any])
        let examFiles = try #require(exam["files"] as? [[String: Any]])
        #expect(examFiles.map { $0["storagePath"] as? String } == ["imagess/a.jpg", "imagess/b.jpg"])
    }
}

import Testing
@testable import ViFi

@Suite("ArchivePublishPlan")
struct ArchivePublishPlanTests {
    // Boğaziçi / Mühendislik / Bilgisayar Mühendisliği / Ayrık Matematik / 2023 VİZE.
    private let record = Fixture.submissionRecord()

    private var expectedUniversityId: String { Slug.make("Boğaziçi Üniversitesi") }
    private var expectedCourseId: String {
        "\(expectedUniversityId)__\(Slug.make("Mühendislik Fakültesi"))__\(Slug.make("Bilgisayar Mühendisliği"))__\(Slug.make("Ayrık Matematik"))"
    }

    @Test("A new university creates the whole chain, each with one child")
    func newUniversityChain() {
        let plan = ArchivePublishPlan.make(record: record, placement: ResolvedPlacement(tier: .newUniversity))

        #expect(plan.universityId == expectedUniversityId)
        #expect(plan.courseId == expectedCourseId)
        #expect(plan.examId == "\(expectedCourseId)__\(Slug.make("2023 VİZE"))")
        #expect(plan.childCountIncrements.isEmpty)
        #expect(plan.nodesToCreate.count == 4)
        #expect(plan.nodesToCreate.allSatisfy { $0.childCount == 1 })

        let university = plan.nodesToCreate.first { $0.level == "university" }
        #expect(university?.id == expectedUniversityId)
        #expect(university?.parentId.isEmpty == true)
        #expect(university?.name == "Boğaziçi Üniversitesi")
        #expect(plan.nodesToCreate.map(\.level).sorted() == ["course", "department", "faculty", "university"])
    }

    @Test("A new exam under an existing course creates no node but bumps the course")
    func newExamBumpsCourse() {
        let placement = ResolvedPlacement(
            tier: .newExam, universityId: "u", facultyId: "f", departmentId: "d", courseId: "c"
        )
        let plan = ArchivePublishPlan.make(record: record, placement: placement)

        #expect(plan.nodesToCreate.isEmpty)
        #expect(plan.childCountIncrements == ["c"])
        #expect(plan.examId == "c__\(Slug.make("2023 VİZE"))")
        #expect(plan.courseId == "c")
    }

    @Test("A new course under an existing department creates the course and bumps the department")
    func newCourseBumpsDepartment() {
        let placement = ResolvedPlacement(
            tier: .newCourse, universityId: "u", facultyId: "f", departmentId: "d"
        )
        let plan = ArchivePublishPlan.make(record: record, placement: placement)

        #expect(plan.nodesToCreate.count == 1)
        #expect(plan.nodesToCreate.first?.level == "course")
        #expect(plan.nodesToCreate.first?.parentId == "d")
        #expect(plan.childCountIncrements == ["d"])
        #expect(plan.examId == "d__\(Slug.make("Ayrık Matematik"))__\(Slug.make("2023 VİZE"))")
    }

    @Test("A duplicate publishes nothing new")
    func duplicatePublishesNothing() {
        let placement = ResolvedPlacement(
            tier: .duplicate, universityId: "u", facultyId: "f", departmentId: "d", courseId: "c", examId: "e"
        )
        let plan = ArchivePublishPlan.make(record: record, placement: placement)

        #expect(plan.nodesToCreate.isEmpty)
        #expect(plan.childCountIncrements.isEmpty)
        #expect(plan.examId == nil)
    }

    @Test("The exam document carries the archive schema and the published files")
    func examDocumentShape() {
        let placement = ResolvedPlacement(
            tier: .newExam, universityId: "u", facultyId: "f", departmentId: "d", courseId: "c"
        )
        let plan = ArchivePublishPlan.make(record: record, placement: placement)
        let files = [
            SubmissionFileRef(storagePath: "imagess/b.jpg", order: 2),
            SubmissionFileRef(storagePath: "imagess/a.jpg", order: 1),
        ]
        let document = plan.examDocument(record: record, files: files)

        #expect(document["title"] as? String == "2023 VİZE")
        #expect(document["courseId"] as? String == "c")
        #expect(document["kind"] as? String == "JPG")
        #expect(document["status"] as? String == "published")
        #expect(document["source"] as? String == "submission")
        #expect(document["isLocked"] as? Bool == false)
        let storedFiles = document["files"] as? [[String: Any]]
        #expect(storedFiles?.count == 2)
        // Sorted by order.
        #expect(storedFiles?.first?["storagePath"] as? String == "imagess/a.jpg")
        #expect(storedFiles?.first?["order"] as? Int == 1)
    }

    @Test("A node's fields match the catalog schema")
    func nodeFields() {
        let plan = ArchivePublishPlan.make(record: record, placement: ResolvedPlacement(tier: .newUniversity))
        let university = plan.nodesToCreate.first { $0.level == "university" }
        let fields = university?.fields
        #expect(fields?["status"] as? String == "published")
        #expect(fields?["source"] as? String == "submission")
        #expect((fields?["parentId"] as? String)?.isEmpty == true)
        #expect(fields?["slug"] as? String == Slug.make("Boğaziçi Üniversitesi"))
        #expect(fields?["childCount"] as? Int == 1)
    }
}

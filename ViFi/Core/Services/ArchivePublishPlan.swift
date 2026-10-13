import Foundation

/// A catalog node to create when publishing a submission, matching the archive's composite-slug id scheme and
/// document shape (`{ level, name, parentId, status, childCount, slug, source }`).
nonisolated struct CatalogNodeWrite: Equatable, Sendable {
    let id: String
    let level: String
    let name: String
    let parentId: String
    let childCount: Int

    /// The Firestore document fields for this node (user-contributed, so `source` is `submission`).
    var fields: [String: Any] {
        [
            "level": level,
            "name": name,
            "parentId": parentId,
            "status": "published",
            "childCount": childCount,
            "slug": Slug.make(name),
            "source": "submission",
        ]
    }
}

/// The plan for publishing one approved submission into the archive: which catalog nodes to create, which
/// existing parents to bump, and the exam document to write.
///
/// Pure and Firestore-free so the id composition and `childCount` bookkeeping are unit-tested. Ids follow the
/// migration's scheme exactly: a university id is `slug(name)`, and each level below is `parentId__slug(name)`,
/// so a free-typed name yields the same id the bundled catalog and FCM topics use.
nonisolated struct ArchivePublishPlan: Equatable, Sendable {
    /// Catalog nodes that do not exist yet and must be created.
    let nodesToCreate: [CatalogNodeWrite]
    /// Ids of existing catalog nodes whose `childCount` should be incremented by one (a new child was added).
    let childCountIncrements: [String]
    /// The exam document id to create, or `nil` when the submission duplicates an existing exam (nothing new is
    /// published — only the low-tier reward is granted).
    let examId: String?
    let universityId: String
    let facultyId: String
    let departmentId: String
    let courseId: String

    static func make(record: ExamSubmissionRecord, placement: ResolvedPlacement) -> ArchivePublishPlan {
        let universityId = placement.universityId ?? Slug.make(record.university)
        let facultyId = placement.facultyId ?? "\(universityId)__\(Slug.make(record.faculty))"
        let departmentId = placement.departmentId ?? "\(facultyId)__\(Slug.make(record.department))"
        let courseId = placement.courseId ?? "\(departmentId)__\(Slug.make(record.lesson))"

        let createUniversity = placement.universityId == nil
        let createFaculty = placement.facultyId == nil
        let createDepartment = placement.departmentId == nil
        let createCourse = placement.courseId == nil
        let isDuplicate = placement.examId != nil

        var nodes: [CatalogNodeWrite] = []
        var increments: [String] = []

        // Nothing new is published for a duplicate: the exam already exists, so no node or count changes.
        if !isDuplicate {
            // Each level is either created (its only child is the one in this chain, so childCount is 1) or, when
            // it already exists and its child is newly created, bumped by one.
            if createCourse {
                nodes.append(.init(id: courseId, level: "course", name: record.lesson, parentId: departmentId, childCount: 1))
            } else {
                increments.append(courseId)
            }
            if createDepartment {
                nodes.append(.init(id: departmentId, level: "department", name: record.department, parentId: facultyId, childCount: 1))
            } else if createCourse {
                increments.append(departmentId)
            }
            if createFaculty {
                nodes.append(.init(id: facultyId, level: "faculty", name: record.faculty, parentId: universityId, childCount: 1))
            } else if createDepartment {
                increments.append(facultyId)
            }
            if createUniversity {
                nodes.append(.init(id: universityId, level: "university", name: record.university, parentId: "", childCount: 1))
            } else if createFaculty {
                increments.append(universityId)
            }
        }

        return ArchivePublishPlan(
            nodesToCreate: nodes,
            childCountIncrements: increments,
            examId: isDuplicate ? nil : "\(courseId)__\(Slug.make(record.exam))",
            universityId: universityId,
            facultyId: facultyId,
            departmentId: departmentId,
            courseId: courseId
        )
    }

    /// The exam document fields, given the files already copied into the public archive storage. Matches the
    /// migration's `exams/<id>` shape; `source` marks it user-contributed.
    func examDocument(record: ExamSubmissionRecord, files: [SubmissionFileRef]) -> [String: Any] {
        [
            "title": record.exam,
            "universityId": universityId,
            "facultyId": facultyId,
            "departmentId": departmentId,
            "courseId": courseId,
            "universityName": record.university,
            "facultyName": record.faculty,
            "departmentName": record.department,
            "courseName": record.lesson,
            "kind": record.kind.rawValue,
            "files": files.sorted { $0.order < $1.order }.map { ["storagePath": $0.storagePath, "order": $0.order] },
            "status": "published",
            "source": "submission",
            "isLocked": false,
            "coinCost": 0,
            "counts": ["views": 0, "downloads": 0, "unlocks": 0],
            "sortKey": record.exam,
        ]
    }
}

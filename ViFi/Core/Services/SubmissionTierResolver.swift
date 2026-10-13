import Foundation

/// Where a submission sits in the archive taxonomy, by display name — the input to the tier resolver.
nonisolated struct SubmissionLocation: Equatable, Sendable {
    var university: String
    var faculty: String
    var department: String
    var lesson: String
    /// The exam's display text with the year folded in, e.g. "2023 VİZE" — matches what the archive stores.
    var examText: String

    init(university: String, faculty: String, department: String, lesson: String, examText: String) {
        self.university = university
        self.faculty = faculty
        self.department = department
        self.lesson = lesson
        self.examText = examText
    }

    /// Builds a location from the add-exam form's separate exam name and year.
    init(university: String, faculty: String, department: String, lesson: String, examName: String, year: Int) {
        self.init(
            university: university, faculty: faculty, department: department, lesson: lesson,
            examText: ExamSubmission.examText(name: examName, year: year)
        )
    }
}

/// How a submission resolves against the live archive: the novelty tier, plus the ids of the catalog nodes that
/// already exist (so the publisher reuses them and only creates what is missing).
nonisolated struct ResolvedPlacement: Equatable, Sendable {
    var tier: SubmissionTier
    var universityId: String?
    var facultyId: String?
    var departmentId: String?
    var courseId: String?
    /// The existing exam's id when the submission duplicates one.
    var examId: String?

    init(
        tier: SubmissionTier,
        universityId: String? = nil,
        facultyId: String? = nil,
        departmentId: String? = nil,
        courseId: String? = nil,
        examId: String? = nil
    ) {
        self.tier = tier
        self.universityId = universityId
        self.facultyId = facultyId
        self.departmentId = departmentId
        self.courseId = courseId
        self.examId = examId
    }
}

/// Works out a submission's novelty tier against the live archive, and the existing nodes it maps onto.
///
/// Reused by the add-exam estimate (tier only, non-binding) and the admin approval (the full placement, to
/// publish). Submissions carry bundled display names, not archive ids, so each level is matched to the archive
/// by name (`ArchiveNameMatch`) — the same tolerant folding the lesson picker uses. The university match is
/// reliable (there are only a handful); the department is looked up across every faculty of the matched
/// university, because the bundled faculty name does not always match the archive's; the faculty name only
/// tells a brand-new faculty apart from a new department under an existing one.
struct SubmissionTierResolver {
    let repository: any ArchiveRepository

    /// The tier for a submission at `location` (a cancelled read propagates `CancellationError`).
    func tier(of location: SubmissionLocation) async throws -> SubmissionTier {
        try await placement(of: location).tier
    }

    /// The full placement: the tier plus the ids of the archive nodes that already exist for this submission.
    func placement(of location: SubmissionLocation) async throws -> ResolvedPlacement {
        let universities = try await repository.items(at: .root)
        guard let universityMatch = universities.first(where: {
            ArchiveNameMatch.matches($0.name, location.university)
        }) else {
            return ResolvedPlacement(tier: .newUniversity)
        }
        let universityId = universityMatch.path.components.last

        // The department is searched under every faculty (faculty names are unreliable); the faculty-name match
        // is only used to tell a new faculty from a new department when the department itself is missing.
        let faculties = try await repository.items(at: universityMatch.path)
        var facultyNameMatch: ArchiveItem?
        var departmentMatch: ArchiveItem?
        var facultyOfDepartment: ArchiveItem?
        for facultyItem in faculties {
            if facultyNameMatch == nil, ArchiveNameMatch.matches(facultyItem.name, location.faculty) {
                facultyNameMatch = facultyItem
            }
            let departments = try await repository.items(at: facultyItem.path)
            if let match = departments.first(where: {
                ArchiveNameMatch.matchesDepartment(archive: $0.name, profile: location.department)
            }) {
                departmentMatch = match
                facultyOfDepartment = facultyItem
                break
            }
        }

        guard let departmentMatch, let facultyOfDepartment else {
            if let facultyNameMatch {
                return ResolvedPlacement(
                    tier: .newDepartment, universityId: universityId,
                    facultyId: facultyNameMatch.path.components.last
                )
            }
            return ResolvedPlacement(tier: .newFaculty, universityId: universityId)
        }

        let facultyId = facultyOfDepartment.path.components.last
        let departmentId = departmentMatch.path.components.last

        let courses = try await repository.items(at: departmentMatch.path)
        guard let courseMatch = courses.first(where: { ArchiveNameMatch.matches($0.name, location.lesson) }) else {
            return ResolvedPlacement(
                tier: .newCourse, universityId: universityId, facultyId: facultyId, departmentId: departmentId
            )
        }
        let courseId = courseMatch.path.components.last

        let exams = try await repository.items(at: courseMatch.path)
        if let examMatch = exams.first(where: { ArchiveNameMatch.matches($0.name, location.examText) }) {
            return ResolvedPlacement(
                tier: .duplicate, universityId: universityId, facultyId: facultyId,
                departmentId: departmentId, courseId: courseId, examId: examMatch.path.components.last
            )
        }
        return ResolvedPlacement(
            tier: .newExam, universityId: universityId, facultyId: facultyId,
            departmentId: departmentId, courseId: courseId
        )
    }
}

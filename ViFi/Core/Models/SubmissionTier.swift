import Foundation

/// How much new content an exam submission adds to the archive: the deepest level of the taxonomy
/// (university → faculty → department → course → exam) at which it introduces something not already there.
///
/// A shallower novelty is worth more — a brand-new university is the most valuable contribution, a duplicate of
/// an exam that already exists the least. The authoritative tier is decided when an admin approves a submission
/// (against the live archive); the add-exam screen shows the same computation up front as a non-binding
/// estimate. The per-tier coin amounts live in remote config (`config/rewards/ios/tiers`) so they can be tuned
/// without an app update.
nonisolated enum SubmissionTier: String, CaseIterable, Sendable {
    /// The university itself is not in the archive — the whole chain is new.
    case newUniversity
    /// The university exists, but this faculty under it is new.
    case newFaculty
    /// The faculty exists, but this department under it is new.
    case newDepartment
    /// The department exists, but this course (lesson) under it is new.
    case newCourse
    /// The course exists, but this exam (name + year) is new for it.
    case newExam
    /// The course already has an exam with the same name and year.
    case duplicate

    /// The tier implied by which archive levels already exist. A level can exist only when its parent does, so
    /// the first missing level from the root down decides the tier; callers must pass consistent flags (an
    /// existing child implies an existing parent).
    static func classify(
        universityExists: Bool,
        facultyExists: Bool,
        departmentExists: Bool,
        courseExists: Bool,
        examExists: Bool
    ) -> SubmissionTier {
        if !universityExists { return .newUniversity }
        if !facultyExists { return .newFaculty }
        if !departmentExists { return .newDepartment }
        if !courseExists { return .newCourse }
        if !examExists { return .newExam }
        return .duplicate
    }

    /// Short Turkish label shown to the user (e.g. in the add-exam coin estimate).
    var label: String {
        switch self {
        case .newUniversity: String(localized: "Yeni üniversite")
        case .newFaculty: String(localized: "Yeni fakülte")
        case .newDepartment: String(localized: "Yeni bölüm")
        case .newCourse: String(localized: "Yeni ders")
        case .newExam: String(localized: "Yeni sınav")
        case .duplicate: String(localized: "Mevcut sınav")
        }
    }
}

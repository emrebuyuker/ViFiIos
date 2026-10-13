import Foundation
import Testing
@testable import ViFi

@MainActor
@Suite("SubmissionTierResolver")
struct SubmissionTierResolverTests {
    // The submission under test, by display name.
    private static let university = "Boğaziçi Üniversitesi"
    private static let faculty = "Mühendislik Fakültesi"
    private static let department = "Bilgisayar Mühendisliği"
    private static let lesson = "Ayrık Matematik"
    private static let examName = "VİZE"
    private static let year = 2023

    private func item(_ name: String, level: ArchiveLevel) -> ArchiveItem {
        ArchiveItem(path: ArchivePath(components: [name], displayNames: [name]), level: level, childCount: nil, exam: nil)
    }

    private func resolve(_ replies: [[ArchiveItem]]) async throws -> SubmissionTier {
        let repository = StubArchiveRepository(items: replies.map { .success($0) })
        let location = SubmissionLocation(
            university: Self.university, faculty: Self.faculty, department: Self.department,
            lesson: Self.lesson, examName: Self.examName, year: Self.year
        )
        return try await SubmissionTierResolver(repository: repository).tier(of: location)
    }

    @Test("A university not in the archive is the top tier")
    func newUniversity() async throws {
        let tier = try await resolve([[item("Başka Üniversite", level: .university)]])
        #expect(tier == .newUniversity)
    }

    @Test("An existing university with no matching faculty or department is a new faculty")
    func newFaculty() async throws {
        let tier = try await resolve([
            [item(Self.university, level: .university)],
            [item("İşletme Fakültesi", level: .faculty)],
            [item("Muhasebe", level: .department)],
        ])
        #expect(tier == .newFaculty)
    }

    @Test("A matching faculty name but a missing department is a new department")
    func newDepartment() async throws {
        let tier = try await resolve([
            [item(Self.university, level: .university)],
            [item(Self.faculty, level: .faculty)],
            [item("Makine Mühendisliği", level: .department)],
        ])
        #expect(tier == .newDepartment)
    }

    @Test("An existing department but a missing course is a new course")
    func newCourse() async throws {
        let tier = try await resolve([
            [item(Self.university, level: .university)],
            [item("Herhangi Fakülte", level: .faculty)],
            [item(Self.department, level: .department)],
            [item("Veri Yapıları", level: .lesson)],
        ])
        #expect(tier == .newCourse)
    }

    @Test("An existing course with no same-dated exam is a new exam")
    func newExam() async throws {
        let tier = try await resolve([
            [item(Self.university, level: .university)],
            [item("Herhangi Fakülte", level: .faculty)],
            [item(Self.department, level: .department)],
            [item(Self.lesson, level: .lesson)],
            [item("2022 VİZE", level: .exam)],
        ])
        #expect(tier == .newExam)
    }

    @Test("An existing same-dated exam of the course is a duplicate")
    func duplicate() async throws {
        let tier = try await resolve([
            [item(Self.university, level: .university)],
            [item("Herhangi Fakülte", level: .faculty)],
            [item(Self.department, level: .department)],
            [item(Self.lesson, level: .lesson)],
            [item("2023 VİZE", level: .exam)],
        ])
        #expect(tier == .duplicate)
    }

    @Test("The department is matched across faculties even when the faculty name differs")
    func departmentFoundUnderDifferentlyNamedFaculty() async throws {
        let tier = try await resolve([
            [item(Self.university, level: .university)],
            // Two faculties; neither name matches "Mühendislik Fakültesi", but the second holds the department.
            [item("Mühendislik ve Doğa Bilimleri Fakültesi", level: .faculty), item("Fen Fakültesi", level: .faculty)],
            [item("Fizik Bölümü", level: .department)],              // under the first faculty: no match
            [item(Self.department, level: .department)],             // under the second faculty: match
            [item(Self.lesson, level: .lesson)],
            [item("2023 VİZE", level: .exam)],
        ])
        #expect(tier == .duplicate)
    }
}

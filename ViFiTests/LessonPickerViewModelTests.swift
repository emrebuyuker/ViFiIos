import Foundation
import Testing
@testable import ViFi

@Suite("LessonPickerViewModel", .timeLimit(.minutes(1)))
struct LessonPickerViewModelTests {
    private func university(_ name: String) -> ArchiveItem {
        ArchiveItem(
            path: ArchivePath(components: [Slug.make(name)], displayNames: [name]),
            level: .university,
            childCount: 1,
            exam: nil
        )
    }

    private func child(of parent: ArchiveItem, _ name: String, level: ArchiveLevel) -> ArchiveItem {
        ArchiveItem(
            path: parent.path.appending(id: Slug.make(name), displayName: name),
            level: level,
            childCount: level == .lesson ? 0 : 1,
            exam: nil
        )
    }

    @Test("Finds the department's courses even when the faculty name does not match the profile's")
    func findsCoursesDespiteFacultyMismatch() async {
        let sakarya = university("SAKARYA ÜNİVERSİTESİ")
        // The archive faculty name differs from any bundled profile faculty.
        let faculty = child(of: sakarya, "BİLGİSAYAR VE BİLİŞİM BİLİMLERİ FAKÜLTESİ", level: .faculty)
        let department = child(of: faculty, "BİLGİSAYAR MÜHENDİSLİĞİ", level: .department)
        let course = child(of: department, "AYRIK İŞLEMSEL YAPILAR", level: .lesson)
        let repository = StubArchiveRepository(items: [
            .success([sakarya]),      // root → universities
            .success([faculty]),      // university → faculties
            .success([department]),   // faculty → departments
            .success([course]),       // department → courses
        ])
        let viewModel = LessonPickerViewModel(
            university: "Sakarya Üniversitesi",
            department: "Bilgisayar Mühendisliği",
            repository: repository
        )

        await viewModel.load()

        #expect(viewModel.courses(matching: "").map(\.name) == ["AYRIK İŞLEMSEL YAPILAR"])
    }

    @Test("Searches every faculty of the university for the department")
    func searchesEveryFaculty() async {
        let sakarya = university("SAKARYA ÜNİVERSİTESİ")
        let facultyA = child(of: sakarya, "FEN FAKÜLTESİ", level: .faculty)
        let facultyB = child(of: sakarya, "MÜHENDİSLİK FAKÜLTESİ", level: .faculty)
        let otherDepartment = child(of: facultyA, "FİZİK", level: .department)
        let department = child(of: facultyB, "BİLGİSAYAR MÜHENDİSLİĞİ", level: .department)
        let course = child(of: department, "AYRIK İŞLEMSEL YAPILAR", level: .lesson)
        let repository = StubArchiveRepository(items: [
            .success([sakarya]),               // root
            .success([facultyA, facultyB]),    // faculties
            .success([otherDepartment]),       // facultyA departments (no match)
            .success([department]),            // facultyB departments (match)
            .success([course]),                // department courses
        ])
        let viewModel = LessonPickerViewModel(
            university: "Sakarya Üniversitesi",
            department: "Bilgisayar Mühendisliği",
            repository: repository
        )

        await viewModel.load()

        #expect(viewModel.courses(matching: "").map(\.name) == ["AYRIK İŞLEMSEL YAPILAR"])
    }

    @Test("Finds the department's courses despite the archive's BÖLÜMÜ suffix")
    func findsCoursesDespiteDepartmentSuffix() async {
        let sakarya = university("SAKARYA ÜNİVERSİTESİ")
        let faculty = child(of: sakarya, "FEN EDEBİYAT FAKÜLTESİ", level: .faculty)
        let department = child(of: faculty, "MATEMATİK BÖLÜMÜ", level: .department)
        let course = child(of: department, "ANALİZ 1", level: .lesson)
        let repository = StubArchiveRepository(items: [
            .success([sakarya]),
            .success([faculty]),
            .success([department]),
            .success([course]),
        ])
        let viewModel = LessonPickerViewModel(
            university: "Sakarya Üniversitesi",
            department: "Matematik",
            repository: repository
        )

        await viewModel.load()

        #expect(viewModel.courses(matching: "").map(\.name) == ["ANALİZ 1"])
    }

    @Test("A university with no archive match yields no courses")
    func noUniversityMatch() async {
        let other = university("BAŞKA ÜNİVERSİTE")
        let repository = StubArchiveRepository(items: [.success([other])])
        let viewModel = LessonPickerViewModel(
            university: "Sakarya Üniversitesi",
            department: "Bilgisayar Mühendisliği",
            repository: repository
        )

        await viewModel.load()

        #expect(viewModel.courses(matching: "").isEmpty)
    }

    @Test("Search filters the loaded courses, Turkish-insensitive")
    func searchFilters() async {
        let sakarya = university("SAKARYA ÜNİVERSİTESİ")
        let faculty = child(of: sakarya, "MÜHENDİSLİK FAKÜLTESİ", level: .faculty)
        let department = child(of: faculty, "BİLGİSAYAR MÜHENDİSLİĞİ", level: .department)
        let discrete = child(of: department, "AYRIK İŞLEMSEL YAPILAR", level: .lesson)
        let networks = child(of: department, "BİLGİSAYAR AĞLARI", level: .lesson)
        let repository = StubArchiveRepository(items: [
            .success([sakarya]),
            .success([faculty]),
            .success([department]),
            .success([discrete, networks]),
        ])
        let viewModel = LessonPickerViewModel(
            university: "Sakarya Üniversitesi",
            department: "Bilgisayar Mühendisliği",
            repository: repository
        )

        await viewModel.load()

        #expect(viewModel.courses(matching: "ayrık").map(\.name) == ["AYRIK İŞLEMSEL YAPILAR"])
        #expect(viewModel.courses(matching: "").count == 2)
    }
}

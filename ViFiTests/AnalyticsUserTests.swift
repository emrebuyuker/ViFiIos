import Foundation
import Testing
@testable import ViFi

@Suite("AnalyticsUser")
struct AnalyticsUserTests {
    @Test("A present profile maps to canonical segment properties")
    func mapsProfile() {
        let user = AnalyticsUser(id: "uid-1", profile: Self.profile(), isAdmin: false)

        #expect(user.id == "uid-1")
        #expect(user.universityId == "bogazici-universitesi")
        #expect(user.facultyId == "muhendislik-fakultesi")
        #expect(user.departmentId == "bilgisayar-muhendisligi")
        #expect(user.gender == "female")
        #expect(user.isAdmin == false)
    }

    @Test("No profile leaves segment properties empty but keeps id and admin")
    func noProfile() {
        let user = AnalyticsUser(id: "uid-2", profile: nil, isAdmin: true)

        #expect(user.id == "uid-2")
        #expect(user.universityId == nil)
        #expect(user.facultyId == nil)
        #expect(user.departmentId == nil)
        #expect(user.gender == nil)
        #expect(user.isAdmin)
    }

    @Test("Properties expose every declared name and encode admin as a string")
    func propertiesDictionary() {
        let user = AnalyticsUser(id: "uid-3", profile: Self.profile(), isAdmin: true)
        let properties = user.properties

        #expect(Set(properties.keys) == Set(AnalyticsUser.propertyNames))
        #expect(properties["is_admin"] == "true")
        #expect(properties["gender"] == "female")
        #expect(properties["university_id"] == "bogazici-universitesi")
    }

    @Test("Long values are clamped to the 36-character analytics limit")
    func clampsLongValues() {
        let longId = String(repeating: "a", count: 50)
        let user = AnalyticsUser(id: "uid-4", profile: Self.profile(departmentId: longId), isAdmin: false)

        // The model keeps the raw value; only the exported property is clamped.
        #expect(user.departmentId == longId)
        #expect(user.properties["department_id"] == String(repeating: "a", count: 36))
    }

    // MARK: - Helpers

    private static func profile(departmentId: String = "bilgisayar-muhendisligi") -> UserProfile {
        UserProfile(
            name: "Ayşe",
            surname: "Yılmaz",
            university: "Boğaziçi Üniversitesi",
            universityId: "bogazici-universitesi",
            universityIsCustom: false,
            faculty: "Mühendislik Fakültesi",
            facultyId: "muhendislik-fakultesi",
            facultyIsCustom: false,
            department: "Bilgisayar Mühendisliği",
            departmentId: departmentId,
            departmentIsCustom: false,
            gender: .female,
            phoneNumber: "+905321234567"
        )
    }
}

import Foundation
import Testing
@testable import ViFi

@Suite("UserProfileParser")
struct UserProfileParserTests {
    private let raw: [String: Any] = [
        "name": "Ayşe",
        "surname": "Yılmaz",
        "university": "Boğaziçi Üniversitesi",
        "universityId": "bogazici-universitesi",
        "universityIsCustom": false,
        "faculty": "Mühendislik Fakültesi",
        "facultyId": "muhendislik-fakultesi",
        "facultyIsCustom": false,
        "department": "Bilgisayar Mühendisliği",
        "departmentId": "bilgisayar-muhendisligi",
        "departmentIsCustom": false,
        "gender": "female",
        "phoneNumber": "+905321234567",
        "updatedAt": 1_700_000_000_000,
    ]

    @Test("A complete snapshot parses into a profile, ignoring updatedAt")
    func parsesValidProfile() {
        #expect(UserProfileParser.profile(from: raw) == Fixture.profile)
    }

    @Test("A missing required field yields nil")
    func rejectsMissingField() {
        let required = [
            "name", "surname",
            "university", "universityId",
            "faculty", "facultyId",
            "department", "departmentId",
            "gender", "phoneNumber",
        ]
        for key in required {
            var dict = raw
            dict[key] = nil
            #expect(UserProfileParser.profile(from: dict) == nil, "missing \(key) should not parse")
        }
    }

    @Test("A missing isCustom flag defaults to false (tolerant read)")
    func missingCustomFlagDefaultsFalse() {
        var dict = raw
        dict["universityIsCustom"] = nil
        #expect(UserProfileParser.profile(from: dict)?.universityIsCustom == false)
    }

    @Test("An empty string field yields nil")
    func rejectsEmptyField() {
        var dict = raw
        dict["name"] = ""
        #expect(UserProfileParser.profile(from: dict) == nil)
    }

    @Test("An unknown gender yields nil")
    func rejectsUnknownGender() {
        var dict = raw
        dict["gender"] = "other"
        #expect(UserProfileParser.profile(from: dict) == nil)
    }

    @Test("A non-object value yields nil")
    func rejectsNonObject() {
        #expect(UserProfileParser.profile(from: "not a profile") == nil)
        #expect(UserProfileParser.profile(from: nil) == nil)
    }

    @Test("The written fields carry names, ids and custom flags, without updatedAt")
    func fieldsForWrite() {
        let fields = UserProfileParser.fields(of: Fixture.profile)
        #expect(fields.count == 13)
        #expect(fields["university"] as? String == "Boğaziçi Üniversitesi")
        #expect(fields["universityId"] as? String == "bogazici-universitesi")
        #expect(fields["universityIsCustom"] as? Bool == false)
        #expect(fields["facultyId"] as? String == "muhendislik-fakultesi")
        #expect(fields["departmentId"] as? String == "bilgisayar-muhendisligi")
        #expect(fields["gender"] as? String == "female")
        #expect(fields["phoneNumber"] as? String == Fixture.profile.phoneNumber)
        #expect(fields["updatedAt"] == nil)
    }
}

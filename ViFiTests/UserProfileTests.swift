import Foundation
import Testing
@testable import ViFi

@Suite("UserProfile")
struct UserProfileTests {
    @Test("Full name joins name and surname")
    func fullName() {
        #expect(Fixture.profile.fullName == "Ayşe Yılmaz")
    }

    @Test("Gender raw values are stable (they are stored in the database)")
    func genderRawValues() {
        #expect(Gender.female.rawValue == "female")
        #expect(Gender.male.rawValue == "male")
        #expect(Gender.allCases == [.female, .male])
        #expect(Gender(rawValue: "other") == nil)
    }

    @Test("A profile survives an encode/decode round trip")
    func codableRoundTrip() throws {
        let data = try JSONEncoder().encode(Fixture.profile)
        let decoded = try JSONDecoder().decode(UserProfile.self, from: data)
        #expect(decoded == Fixture.profile)
    }
}

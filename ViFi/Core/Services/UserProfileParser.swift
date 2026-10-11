import Foundation

/// Turns a raw `users/<uid>/profile` value (`DataSnapshot.value`) into a `UserProfile`, and a profile back
/// into the child values written to the database.
///
/// Pure and Firebase-free so it can be unit-tested with plain dictionaries. The `updatedAt` timestamp is added
/// by the service (a server value), so it is deliberately not part of the written fields here.
nonisolated enum UserProfileParser {
    /// A profile from a raw snapshot value, or `nil` when a required field is missing or malformed.
    static func profile(from value: Any?) -> UserProfile? {
        guard let entries = value as? [String: Any],
              let name = string(entries["name"]),
              let surname = string(entries["surname"]),
              let university = string(entries["university"]),
              let universityId = string(entries["universityId"]),
              let faculty = string(entries["faculty"]),
              let facultyId = string(entries["facultyId"]),
              let department = string(entries["department"]),
              let departmentId = string(entries["departmentId"]),
              let genderRaw = entries["gender"] as? String,
              let gender = Gender(rawValue: genderRaw),
              let phoneNumber = string(entries["phoneNumber"]) else {
            return nil
        }
        return UserProfile(
            name: name,
            surname: surname,
            university: university,
            universityId: universityId,
            universityIsCustom: bool(entries["universityIsCustom"]),
            faculty: faculty,
            facultyId: facultyId,
            facultyIsCustom: bool(entries["facultyIsCustom"]),
            department: department,
            departmentId: departmentId,
            departmentIsCustom: bool(entries["departmentIsCustom"]),
            gender: gender,
            phoneNumber: phoneNumber
        )
    }

    /// The stored fields of `profile` (without `updatedAt`), for a database write.
    static func fields(of profile: UserProfile) -> [String: Any] {
        [
            "name": profile.name,
            "surname": profile.surname,
            "university": profile.university,
            "universityId": profile.universityId,
            "universityIsCustom": profile.universityIsCustom,
            "faculty": profile.faculty,
            "facultyId": profile.facultyId,
            "facultyIsCustom": profile.facultyIsCustom,
            "department": profile.department,
            "departmentId": profile.departmentId,
            "departmentIsCustom": profile.departmentIsCustom,
            "gender": profile.gender.rawValue,
            "phoneNumber": profile.phoneNumber,
        ]
    }

    /// A non-empty string leaf, or `nil`.
    private static func string(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    /// A boolean leaf; `false` when missing or malformed (tolerant on read).
    private static func bool(_ value: Any?) -> Bool {
        (value as? Bool) ?? false
    }
}

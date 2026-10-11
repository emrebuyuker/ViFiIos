import Foundation

/// A signed-in user's profile, collected right after phone verification and stored under
/// `users/<uid>/profile`. The whole app gates on it: the archive is shown only once it exists.
///
/// Pure value type, independent of Firebase, so validation and the form are unit-testable. The phone
/// number is not entered by the user; it mirrors the verified number from the auth token.
nonisolated struct UserProfile: Hashable, Codable, Sendable {
    /// Longest accepted name or surname.
    static let maxNameLength = 60
    /// Longest accepted university or department (matches the archive's node-name limit).
    static let maxFieldLength = 120

    let name: String
    let surname: String

    /// University display name and its canonical id (used for notification segments / FCM topics).
    /// `universityIsCustom` is `true` when the user typed a value that was not on the bundled list.
    let university: String
    let universityId: String
    let universityIsCustom: Bool

    let faculty: String
    let facultyId: String
    let facultyIsCustom: Bool

    let department: String
    let departmentId: String
    let departmentIsCustom: Bool

    let gender: Gender
    /// The verified number the profile belongs to, in E.164 (`+905321234567`); set from the auth token.
    let phoneNumber: String

    /// `Ad Soyad`.
    var fullName: String {
        "\(name) \(surname)"
    }
}

/// How the user describes their gender.
nonisolated enum Gender: String, Codable, Sendable, CaseIterable, Identifiable {
    case female
    case male

    var id: String { rawValue }

    /// The Turkish label shown in the UI.
    var label: String {
        switch self {
        case .female: String(localized: "Kadın")
        case .male: String(localized: "Erkek")
        }
    }
}

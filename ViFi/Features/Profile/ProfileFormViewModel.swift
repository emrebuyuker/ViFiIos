import Foundation
import Observation

/// Backs both the profile-completion gate and the account's edit-profile screen: the editable fields, their
/// validation, and the save. The phone number is not editable; it comes from the verified auth token.
///
/// Work runs in a task the model owns and returns (so tests can await it), holding the model weakly like the
/// other view models. On success it calls `onSaved`, which opens the gate (completion) or pops the sheet (edit).
@Observable
final class ProfileFormViewModel {
    var name: String
    var surname: String
    var university: CatalogSelection
    var faculty: CatalogSelection
    var department: CatalogSelection
    var gender: Gender?

    private(set) var isWorking = false
    private(set) var errorMessage: String?

    /// The verified number, shown read-only; `nil` only for the unexpected case of an account without one.
    let phoneNumber: String?
    let catalog: UniversityCatalog

    @ObservationIgnored private let uid: String
    @ObservationIgnored private let profileService: any ProfileServicing
    @ObservationIgnored private let onSaved: (UserProfile) -> Void

    /// - Parameters:
    ///   - user: The signed-in user; supplies the uid and the read-only phone number.
    ///   - existing: The current profile when editing, `nil` when completing for the first time.
    ///   - onSaved: Called with the saved profile on success (opens the gate, or dismisses the editor).
    init(
        user: AuthUser,
        existing: UserProfile?,
        profileService: any ProfileServicing,
        catalog: UniversityCatalog,
        onSaved: @escaping (UserProfile) -> Void
    ) {
        uid = user.id
        phoneNumber = user.phoneNumber ?? existing?.phoneNumber
        self.profileService = profileService
        self.catalog = catalog
        self.onSaved = onSaved
        name = existing?.name ?? ""
        surname = existing?.surname ?? ""
        university = existing.map { .stored(name: $0.university, id: $0.universityId, isCustom: $0.universityIsCustom) } ?? .empty
        faculty = existing.map { .stored(name: $0.faculty, id: $0.facultyId, isCustom: $0.facultyIsCustom) } ?? .empty
        department = existing.map { .stored(name: $0.department, id: $0.departmentId, isCustom: $0.departmentIsCustom) } ?? .empty
        gender = existing?.gender
    }

    /// `+90 532 123 45 67`, or a placeholder when the account has no number.
    var formattedPhoneNumber: String {
        guard let phoneNumber else { return String(localized: "Telefon numarası yok") }
        return PhoneNumber(e164: phoneNumber)?.formatted ?? phoneNumber
    }

    var canSave: Bool {
        !isWorking && builtProfile != nil
    }

    /// The validated profile from the current fields, or `nil` when something is missing or invalid.
    /// The database rules enforce the full character set; this keeps the Save button honest and trims input.
    private var builtProfile: UserProfile? {
        guard let phoneNumber, let gender,
              let name = Self.validField(name, max: UserProfile.maxNameLength),
              let surname = Self.validField(surname, max: UserProfile.maxNameLength),
              let uni = Self.validSelection(university),
              let fac = Self.validSelection(faculty),
              let dep = Self.validSelection(department) else {
            return nil
        }
        return UserProfile(
            name: name,
            surname: surname,
            university: uni.name,
            universityId: uni.id,
            universityIsCustom: uni.isCustom,
            faculty: fac.name,
            facultyId: fac.id,
            facultyIsCustom: fac.isCustom,
            department: dep.name,
            departmentId: dep.id,
            departmentIsCustom: dep.isCustom,
            gender: gender,
            phoneNumber: phoneNumber
        )
    }

    /// Validates a catalog selection's display name and resolves its canonical id (the catalog id, or a
    /// best-effort slug for a custom value). `nil` when the name is empty, too long, or has a forbidden char.
    private static func validSelection(_ selection: CatalogSelection) -> CatalogSelection? {
        guard let name = validField(selection.name, max: UserProfile.maxFieldLength) else { return nil }
        let id = selection.isCustom ? Slug.make(name) : selection.id
        guard !id.isEmpty else { return nil }
        return CatalogSelection(name: name, id: id, isCustom: selection.isCustom)
    }

    // MARK: - Actions

    /// Saves the profile. Ignored while a save is already running.
    @discardableResult
    func save() -> Task<Void, Never>? {
        guard !isWorking, let profile = builtProfile else { return nil }
        isWorking = true
        errorMessage = nil
        let profileService = profileService
        let uid = uid
        let onSaved = onSaved
        return Task { [weak self] in
            do {
                try await profileService.saveProfile(profile, uid: uid)
                onSaved(profile)
            } catch {
                self?.fail(with: error)
            }
        }
    }

    // MARK: - Private

    private func fail(with error: any Error) {
        isWorking = false
        guard !(error is CancellationError) else { return }
        errorMessage = error.userMessage
    }

    /// The trimmed, space-collapsed value, or `nil` when it is empty, too long, or contains a character the
    /// database forbids in this position.
    private static func validField(_ input: String, max: Int) -> String? {
        let normalized = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        guard !normalized.isEmpty, normalized.count <= max,
              normalized.rangeOfCharacter(from: forbiddenCharacters) == nil else {
            return nil
        }
        return normalized
    }

    /// Characters the Realtime Database rejects in a value (and control characters).
    private static let forbiddenCharacters: CharacterSet = {
        var set = CharacterSet(charactersIn: ".$#[]/")
        set.formUnion(.controlCharacters)
        set.formUnion(.newlines)
        return set
    }()
}

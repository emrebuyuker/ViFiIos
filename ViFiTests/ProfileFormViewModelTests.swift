import Foundation
import Testing
@testable import ViFi

@Suite("ProfileFormViewModel", .timeLimit(.minutes(1)))
struct ProfileFormViewModelTests {
    private func makeViewModel(
        existing: UserProfile? = nil,
        service: StubProfileService = StubProfileService(),
        onSaved: @escaping (UserProfile) -> Void = { _ in }
    ) -> ProfileFormViewModel {
        ProfileFormViewModel(
            user: Fixture.user,
            existing: existing,
            profileService: service,
            catalog: Fixture.catalog,
            onSaved: onSaved
        )
    }

    /// Fills every required field with valid catalog selections.
    private func fillValid(_ viewModel: ProfileFormViewModel) {
        viewModel.name = "Ayşe"
        viewModel.surname = "Yılmaz"
        viewModel.university = .catalog(Fixture.catalog.universities[0]) // Boğaziçi Üniversitesi
        viewModel.faculty = .catalog(Fixture.catalog.faculties[0])       // Mühendislik Fakültesi
        viewModel.department = .catalog(Fixture.catalog.departments[0])  // Bilgisayar Mühendisliği
        viewModel.gender = .female
    }

    @Test("Empty fields cannot be saved")
    func emptyIsNotSavable() {
        #expect(!makeViewModel().canSave)
    }

    @Test("A fully filled form can be saved")
    func completeIsSavable() {
        let viewModel = makeViewModel()
        fillValid(viewModel)
        #expect(viewModel.canSave)
    }

    @Test("A missing gender blocks save")
    func missingGenderBlocksSave() {
        let viewModel = makeViewModel()
        fillValid(viewModel)
        viewModel.gender = nil
        #expect(!viewModel.canSave)
    }

    @Test("A missing university selection blocks save")
    func missingSelectionBlocksSave() {
        let viewModel = makeViewModel()
        fillValid(viewModel)
        viewModel.university = .empty
        #expect(!viewModel.canSave)
    }

    @Test("An editing form is prefilled from the existing profile")
    func existingProfilePrefills() {
        let viewModel = makeViewModel(existing: Fixture.profile)
        #expect(viewModel.name == Fixture.profile.name)
        #expect(viewModel.university.name == Fixture.profile.university)
        #expect(viewModel.university.id == Fixture.profile.universityId)
        #expect(viewModel.faculty.id == Fixture.profile.facultyId)
        #expect(viewModel.department.id == Fixture.profile.departmentId)
        #expect(viewModel.gender == Fixture.profile.gender)
        #expect(viewModel.canSave)
    }

    @Test("The phone number is read-only, taken from the signed-in user")
    func phoneNumberIsReadOnly() {
        #expect(makeViewModel().phoneNumber == Fixture.user.phoneNumber)
    }

    @Test("Saving a catalog selection sends its canonical id, not custom")
    func saveSendsCanonicalIds() async {
        let service = StubProfileService()
        let viewModel = makeViewModel(service: service)
        fillValid(viewModel)

        await viewModel.save()?.value

        let saved = service.savedProfiles.first
        #expect(saved?.universityId == "bogazici-universitesi")
        #expect(saved?.universityIsCustom == false)
        #expect(saved?.facultyId == "muhendislik-fakultesi")
        #expect(saved?.departmentId == "bilgisayar-muhendisligi")
        #expect(viewModel.errorMessage == nil)
    }

    @Test("A free-typed value is marked custom and slugged")
    func customSelectionIsSluggedAndFlagged() async {
        let service = StubProfileService()
        let viewModel = makeViewModel(service: service)
        fillValid(viewModel)
        viewModel.university = .custom("Küçük Köy Üniversitesi")

        await viewModel.save()?.value

        let saved = service.savedProfiles.first
        #expect(saved?.university == "Küçük Köy Üniversitesi")
        #expect(saved?.universityId == "kucuk-koy-universitesi")
        #expect(saved?.universityIsCustom == true)
    }

    @Test("Saving trims the name")
    func saveTrimsName() async {
        let service = StubProfileService()
        let viewModel = makeViewModel(service: service)
        fillValid(viewModel)
        viewModel.name = "  Ayşe  "

        await viewModel.save()?.value

        #expect(service.savedProfiles.first?.name == "Ayşe")
    }

    @Test("A save failure surfaces an error and stops working")
    func saveFailureShowsError() async {
        let service = StubProfileService()
        service.saveReplies = [.failure(ProfileError.offline)]
        let viewModel = makeViewModel(service: service)
        fillValid(viewModel)

        await viewModel.save()?.value

        #expect(viewModel.errorMessage == ProfileError.offline.userMessage)
        #expect(!viewModel.isWorking)
        #expect(service.savedProfiles.isEmpty)
    }

    @Test("A database-illegal character blocks save")
    func forbiddenCharacterBlocksSave() {
        let viewModel = makeViewModel()
        fillValid(viewModel)
        viewModel.name = "Ay/şe"
        #expect(!viewModel.canSave)
    }
}

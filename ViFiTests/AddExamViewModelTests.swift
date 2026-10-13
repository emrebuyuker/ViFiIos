import Foundation
import Testing
@testable import ViFi

@Suite("AddExamViewModel", .timeLimit(.minutes(1)))
struct AddExamViewModelTests {
    private func makeViewModel(
        ownerId: String = Fixture.user.id,
        profile: UserProfile? = nil,
        service: StubExamSubmissionService = StubExamSubmissionService(),
        onSubmitted: @escaping () -> Void = {}
    ) -> AddExamViewModel {
        AddExamViewModel(
            ownerId: ownerId,
            profile: profile,
            catalog: Fixture.catalog,
            submissionService: service,
            currentYear: 2024,
            onSubmitted: onSubmitted
        )
    }

    /// Fills a valid PDF submission (no image encoding needed for the model's own logic).
    private func fillValid(_ viewModel: AddExamViewModel) {
        viewModel.university = .catalog(Fixture.catalog.universities[0])  // Boğaziçi Üniversitesi
        viewModel.faculty = .catalog(Fixture.catalog.faculties[0])        // Mühendislik Fakültesi
        viewModel.department = .catalog(Fixture.catalog.departments[0])   // Bilgisayar Mühendisliği
        viewModel.lesson = .custom("Ayrık Matematik")
        viewModel.examName = .catalog(ExamNameCatalog.names[0])           // VİZE
        viewModel.kind = .pdf
        viewModel.setPDF(Data([1, 2, 3]))
    }

    @Test("An empty form cannot be submitted")
    func emptyNotSubmittable() {
        #expect(!makeViewModel().canSubmit)
    }

    @Test("A complete form can be submitted")
    func completeIsSubmittable() {
        let viewModel = makeViewModel()
        fillValid(viewModel)
        #expect(viewModel.canSubmit)
    }

    @Test("University, faculty and department are pre-filled from the profile")
    func prefillsFromProfile() {
        let viewModel = makeViewModel(profile: Fixture.profile)
        #expect(viewModel.university.name == Fixture.profile.university)
        #expect(viewModel.university.id == Fixture.profile.universityId)
        #expect(viewModel.faculty.id == Fixture.profile.facultyId)
        #expect(viewModel.department.id == Fixture.profile.departmentId)
        #expect(viewModel.lesson.isEmpty)
        #expect(viewModel.examName.isEmpty)
    }

    @Test("A missing course blocks submission")
    func missingLessonBlocks() {
        let viewModel = makeViewModel()
        fillValid(viewModel)
        viewModel.lesson = .empty
        #expect(!viewModel.canSubmit)
    }

    @Test("A missing exam name blocks submission")
    func missingExamNameBlocks() {
        let viewModel = makeViewModel()
        fillValid(viewModel)
        viewModel.examName = .empty
        #expect(!viewModel.canSubmit)
    }

    @Test("A missing university blocks submission")
    func missingUniversityBlocks() {
        let viewModel = makeViewModel()
        fillValid(viewModel)
        viewModel.university = .empty
        #expect(!viewModel.canSubmit)
    }

    @Test("Missing files block submission")
    func missingFilesBlocks() {
        let viewModel = makeViewModel()
        fillValid(viewModel)
        viewModel.clearFiles()
        #expect(!viewModel.canSubmit)
    }

    @Test("An empty owner id blocks submission")
    func missingOwnerBlocks() {
        let viewModel = makeViewModel(ownerId: "")
        fillValid(viewModel)
        #expect(!viewModel.canSubmit)
    }

    @Test("Switching the kind clears the picked files")
    func switchingKindClearsFiles() {
        let viewModel = makeViewModel()
        viewModel.kind = .pdf
        viewModel.setPDF(Data([1, 2]))
        #expect(!viewModel.files.isEmpty)

        viewModel.kind = .images
        #expect(viewModel.files.isEmpty)
    }

    @Test("A PDF over the size limit is rejected with a message")
    func oversizePDFRejected() {
        let viewModel = makeViewModel()
        viewModel.kind = .pdf
        viewModel.setPDF(Data(count: ExamSubmission.maxFileBytes + 1))
        #expect(viewModel.files.isEmpty)
        #expect(viewModel.errorMessage != nil)
    }

    @Test("Submitting sends the chosen names, folded exam text and owner id")
    func submitSendsSubmission() async {
        let service = StubExamSubmissionService()
        let viewModel = makeViewModel(service: service)
        fillValid(viewModel)

        await viewModel.submit()?.value

        #expect(service.calls == [StubExamSubmissionService.Call(ownerId: Fixture.user.id)])
        let submitted = service.submitted.first
        #expect(submitted?.university == "Boğaziçi Üniversitesi")
        #expect(submitted?.faculty == "Mühendislik Fakültesi")
        #expect(submitted?.department == "Bilgisayar Mühendisliği")
        #expect(submitted?.lesson == "Ayrık Matematik")
        #expect(submitted?.examName == "VİZE")
        #expect(submitted?.year == 2024)
        #expect(submitted?.kind == .pdf)
        #expect(viewModel.errorMessage == nil)
        // isWorking stays set on success: the screen dismisses, matching ProfileFormViewModel/LoginViewModel.
    }

    @Test("A submit failure surfaces an error and stops working")
    func submitFailureShowsError() async {
        let service = StubExamSubmissionService()
        service.submitReplies = [.failure(ExamSubmissionError.offline)]
        let viewModel = makeViewModel(service: service)
        fillValid(viewModel)

        await viewModel.submit()?.value

        #expect(viewModel.errorMessage == ExamSubmissionError.offline.userMessage)
        #expect(!viewModel.isWorking)
        #expect(service.submitted.isEmpty)
    }

    @Test("A successful submit calls the completion handler")
    func submitCallsCompletion() async {
        var completed = 0
        let viewModel = makeViewModel(onSubmitted: { completed += 1 })
        fillValid(viewModel)

        await viewModel.submit()?.value

        #expect(completed == 1)
    }
}

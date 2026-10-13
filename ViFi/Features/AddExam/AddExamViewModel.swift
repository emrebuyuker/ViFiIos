import Foundation
import Observation

/// Collects and submits a user-contributed exam.
///
/// University / faculty / department are chosen from the same bundled lists the profile uses (list-only, no
/// free text), and are pre-filled from the signed-in user's profile. The course is picked from the archive's
/// existing courses for that department or typed in (`LessonPickerView`), and the exam name is chosen from a
/// fixed list (`ExamNameCatalog`). `builtSubmission` is a pure, testable assembly of the validated fields; the
/// stored submission keeps only the display-name text (ids are kept client-side for later segmentation).
@Observable
final class AddExamViewModel {
    var university: CatalogSelection
    var faculty: CatalogSelection
    var department: CatalogSelection
    var lesson: CatalogSelection = .empty
    var examName: CatalogSelection = .empty
    var year: Int
    /// Switching the kind clears the already-picked files, which belong to the other kind.
    var kind: ExamKind = .images {
        didSet {
            guard kind != oldValue else { return }
            files.removeAll()
            errorMessage = nil
        }
    }

    private(set) var files: [SubmissionFile] = []
    private(set) var isWorking = false
    /// Set while picked images are being transcoded, so the submit button waits for them.
    private(set) var isPreparingFiles = false
    private(set) var errorMessage: String?

    /// The bundled lists backing the university / faculty / department pickers.
    let catalog: UniversityCatalog

    @ObservationIgnored private let ownerId: String
    @ObservationIgnored private let submissionService: any ExamSubmissionServicing
    @ObservationIgnored private let onSubmitted: () -> Void

    init(
        ownerId: String,
        profile: UserProfile?,
        catalog: UniversityCatalog,
        submissionService: any ExamSubmissionServicing,
        currentYear: Int,
        onSubmitted: @escaping () -> Void
    ) {
        self.ownerId = ownerId
        self.catalog = catalog
        self.submissionService = submissionService
        year = currentYear
        self.onSubmitted = onSubmitted

        if let profile {
            university = .stored(name: profile.university, id: profile.universityId, isCustom: profile.universityIsCustom)
            faculty = .stored(name: profile.faculty, id: profile.facultyId, isCustom: profile.facultyIsCustom)
            department = .stored(name: profile.department, id: profile.departmentId, isCustom: profile.departmentIsCustom)
        } else {
            university = .empty
            faculty = .empty
            department = .empty
        }
    }

    // MARK: - Derived state

    /// A short description of the picked files for the files row.
    var fileSummary: String? {
        guard !files.isEmpty else { return nil }
        switch kind {
        case .images:
            return String(localized: "\(files.count) sayfa seçildi")
        case .pdf:
            return String(localized: "PDF seçildi")
        }
    }

    var canSubmit: Bool {
        !isWorking && !isPreparingFiles && builtSubmission != nil
    }

    /// The validated submission, or `nil` while any field is missing or invalid. Pure — unit-tested without
    /// Firebase.
    private var builtSubmission: ExamSubmission? {
        guard !ownerId.isEmpty,
              let university = Self.validName(university.name),
              let faculty = Self.validName(faculty.name),
              let department = Self.validName(department.name),
              let lesson = Self.validName(lesson.name),
              let examName = Self.validName(examName.name),
              !files.isEmpty else { return nil }
        let submission = ExamSubmission(
            university: university,
            faculty: faculty,
            department: department,
            lesson: lesson,
            examName: examName,
            year: year,
            kind: kind,
            files: files
        )
        return submission.isValid ? submission : nil
    }

    // MARK: - Files

    /// Transcodes picked images to JPEG and appends them in reading order, dropping any that cannot be encoded
    /// or would exceed the page limit.
    func addImages(_ imageData: [Data]) async {
        guard kind == .images, !imageData.isEmpty else { return }
        isPreparingFiles = true
        errorMessage = nil
        defer { isPreparingFiles = false }

        var added: [SubmissionFile] = []
        for data in imageData {
            guard files.count + added.count < ExamSubmission.maxFileCount else {
                errorMessage = String(localized: "En fazla \(ExamSubmission.maxFileCount) sayfa ekleyebilirsin.")
                break
            }
            if let jpeg = await SubmissionFileEncoder.jpeg(from: data, maxBytes: ExamSubmission.maxFileBytes) {
                added.append(SubmissionFile(data: jpeg, order: 0))
            } else {
                errorMessage = String(localized: "Bir görsel işlenemedi. Lütfen başka bir görsel dene.")
            }
        }
        files.append(contentsOf: added)
        renumberFiles()
    }

    /// Sets the single PDF file after checking it is non-empty and within the size limit.
    func setPDF(_ data: Data) {
        guard kind == .pdf else { return }
        errorMessage = nil
        guard !data.isEmpty else {
            errorMessage = String(localized: "Dosya boş görünüyor. Lütfen başka bir dosya seç.")
            return
        }
        guard data.count <= ExamSubmission.maxFileBytes else {
            errorMessage = String(localized: "PDF 15 MB'tan büyük olamaz.")
            return
        }
        files = [SubmissionFile(data: data, order: 1)]
    }

    /// Reports that a picked file could not be read (e.g. a security-scoped URL failed).
    func reportFileReadFailure() {
        errorMessage = String(localized: "Dosya okunamadı. Lütfen tekrar dene.")
    }

    func clearFiles() {
        files.removeAll()
        errorMessage = nil
    }

    // MARK: - Submit

    @discardableResult
    func submit() -> Task<Void, Never>? {
        guard !isWorking, let submission = builtSubmission else { return nil }
        isWorking = true
        errorMessage = nil
        let submissionService = submissionService
        let ownerId = ownerId
        let onSubmitted = onSubmitted
        return Task { [weak self] in
            do {
                try await submissionService.submit(submission, ownerId: ownerId)
                onSubmitted()
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

    /// Reassigns 1-based orders by the current array order, so the file positions stay contiguous.
    private func renumberFiles() {
        files = files.enumerated().map { SubmissionFile(data: $0.element.data, order: $0.offset + 1) }
    }

    /// A trimmed, whitespace-collapsed field value, or `nil` when empty or too long.
    private static func validName(_ input: String) -> String? {
        let normalized = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        guard !normalized.isEmpty, normalized.count <= ExamSubmission.maxTextLength else { return nil }
        return normalized
    }
}

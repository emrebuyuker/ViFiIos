import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// The "Sınav Ekle" flow: university / faculty / department are picked from the bundled lists (pre-filled from
/// the profile), the course from the archive's existing courses or typed in, the exam name from a fixed list,
/// then image pages or a PDF are attached and submitted for moderation. Presented as a sheet from the home
/// screen.
struct AddExamView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AddExamScreen(
            ownerId: environment.session.user?.id ?? "",
            profile: environment.profile.profile,
            catalog: environment.catalog,
            submissionService: environment.submissionService,
            rewardsConfig: environment.rewardsConfig,
            repository: environment.repository,
            analytics: environment.analytics,
            onSubmitted: { dismiss() }
        )
        .onAppear { environment.analytics.track(.screenView(name: "AddExam")) }
    }
}

/// The screen itself, owning the view model for its lifetime.
private struct AddExamScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: AddExamViewModel
    @State private var isImportingPDF = false
    @State private var photoSelection: [PhotosPickerItem] = []
    /// The latest remote reward config, and the novelty tier estimated for the current selection.
    @State private var rewardsConfig: RewardsConfig?
    @State private var estimatedTier: SubmissionTier?

    private let currentYear: Int
    private let rewardsConfigReader: any RewardsConfigReading
    private let resolver: SubmissionTierResolver

    init(
        ownerId: String,
        profile: UserProfile?,
        catalog: UniversityCatalog,
        submissionService: any ExamSubmissionServicing,
        rewardsConfig: any RewardsConfigReading,
        repository: any ArchiveRepository,
        analytics: any AnalyticsTracking,
        onSubmitted: @escaping () -> Void
    ) {
        let year = Calendar.current.component(.year, from: .now)
        currentYear = year
        rewardsConfigReader = rewardsConfig
        resolver = SubmissionTierResolver(repository: repository)
        _viewModel = State(initialValue: AddExamViewModel(
            ownerId: ownerId,
            profile: profile,
            catalog: catalog,
            submissionService: submissionService,
            analytics: analytics,
            currentYear: year,
            onSubmitted: onSubmitted
        ))
    }

    private var yearOptions: [Int] {
        Array((2000...currentYear).reversed())
    }

    var body: some View {
        NavigationStack {
            Form {
                schoolSection
                lessonSection
                examSection
                filesSection
                coinNoteSection

                if let message = viewModel.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("addExam.error")
                    }
                }
            }
            .navigationTitle("Sınav Ekle")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .interactiveDismissDisabled(viewModel.isWorking)
            .animation(.smooth, value: viewModel.errorMessage)
            .animation(.smooth, value: viewModel.files)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { dismiss() }
                        .disabled(viewModel.isWorking)
                        .accessibilityIdentifier("addExam.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isWorking {
                        ProgressView()
                    } else {
                        Button("Gönder") { viewModel.submit(estimatedTier: estimatedTier) }
                            .disabled(!viewModel.canSubmit)
                            .accessibilityIdentifier("addExam.submit")
                    }
                }
            }
            .fileImporter(isPresented: $isImportingPDF, allowedContentTypes: [.pdf]) { result in
                importPDF(result)
            }
            .task { await observeRewards() }
            .task(id: estimateKey) { await updateEstimate() }
            .animation(.smooth, value: estimatedTier)
        }
    }

    // MARK: - Sections

    private var schoolSection: some View {
        Section("Okul") {
            catalogRow(
                title: "Üniversite",
                selection: Bindable(viewModel).university,
                options: viewModel.catalog.universities,
                identifier: "addExam.university"
            )
            catalogRow(
                title: "Fakülte",
                selection: Bindable(viewModel).faculty,
                options: viewModel.catalog.faculties,
                identifier: "addExam.faculty"
            )
            catalogRow(
                title: "Bölüm",
                selection: Bindable(viewModel).department,
                options: viewModel.catalog.departments,
                identifier: "addExam.department"
            )
        }
    }

    private var lessonSection: some View {
        Section("Ders") {
            let value = viewModel.lesson.name
            NavigationLink {
                LessonPickerView(
                    university: viewModel.university.name,
                    department: viewModel.department.name,
                    selection: Bindable(viewModel).lesson
                )
            } label: {
                LabeledContent("Ders") {
                    Text(value.isEmpty ? String(localized: "Seç") : value)
                        .foregroundStyle(value.isEmpty ? .secondary : .primary)
                        .multilineTextAlignment(.trailing)
                }
            }
            .disabled(viewModel.isWorking || viewModel.department.name.isEmpty)
            .accessibilityIdentifier("addExam.lesson")
            .accessibilityValue(Text(value))
        }
    }

    private var examSection: some View {
        Section("Sınav") {
            catalogRow(
                title: "Sınav adı",
                selection: Bindable(viewModel).examName,
                options: ExamNameCatalog.names,
                identifier: "addExam.examName"
            )

            Picker("Yıl", selection: Bindable(viewModel).year) {
                ForEach(yearOptions, id: \.self) { year in
                    Text(verbatim: String(year)).tag(year)
                }
            }
            .disabled(viewModel.isWorking)
            .accessibilityIdentifier("addExam.year")

            Picker("Tür", selection: Bindable(viewModel).kind) {
                ForEach(ExamKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isWorking)
            .accessibilityIdentifier("addExam.kind")
        }
    }

    @ViewBuilder
    private var filesSection: some View {
        Section {
            if viewModel.kind == .images {
                PhotosPicker(
                    selection: $photoSelection,
                    maxSelectionCount: ExamSubmission.maxFileCount,
                    matching: .images
                ) {
                    Label("Görsel sayfa ekle", systemImage: "photo.on.rectangle.angled")
                }
                .disabled(viewModel.isWorking || viewModel.isPreparingFiles)
                .accessibilityIdentifier("addExam.pickImages")
            } else {
                Button {
                    isImportingPDF = true
                } label: {
                    Label(viewModel.files.isEmpty ? "PDF seç" : "PDF'i değiştir", systemImage: "doc.fill")
                }
                .disabled(viewModel.isWorking)
                .accessibilityIdentifier("addExam.pickPDF")
            }

            if viewModel.isPreparingFiles {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Dosyalar hazırlanıyor…")
                        .foregroundStyle(.secondary)
                }
            } else if let summary = viewModel.fileSummary {
                LabeledContent(summary) {
                    Button("Temizle", role: .destructive) {
                        viewModel.clearFiles()
                    }
                    .disabled(viewModel.isWorking)
                    .accessibilityIdentifier("addExam.clearFiles")
                }
            }
        } header: {
            Text("Dosyalar")
        } footer: {
            Text(viewModel.kind == .images
                ? "Sınavın sayfalarını sırayla ekle. En fazla \(ExamSubmission.maxFileCount) görsel."
                : "Sınavı tek bir PDF olarak ekle.")
        }
        .onChange(of: photoSelection) { _, items in
            loadImages(items)
        }
    }

    private var coinNoteSection: some View {
        Section {
            Label {
                Text(coinNoteText)
                    .font(.footnote)
            } icon: {
                Image(systemName: "bitcoinsign.circle.fill")
                    .foregroundStyle(.orange)
            }
            .accessibilityIdentifier("addExam.coinNote")
        }
    }

    /// A tier-specific estimate once the whole placement is known and configured, otherwise the flat amount, and
    /// otherwise a generic promise. Labelled "yaklaşık" because the authoritative amount is set at approval.
    private var coinNoteText: LocalizedStringKey {
        if let estimatedTier, let coins = rewardsConfig?.coins(for: estimatedTier) {
            "Onaylanırsa yaklaşık \(coins) coin kazanırsın (\(estimatedTier.label)); coinlerin hesabına yüklenir."
        } else if let coins = rewardsConfig?.examUploadCoins {
            "Onaylanırsa \(coins) coin kazanırsın; coinlerin hesabına yüklenir."
        } else {
            "Eklediğin sınav incelenip onaylandığında coin kazanırsın; coinlerin hesabına yüklenir."
        }
    }

    /// Changes whenever a level of the placement changes, so the tier estimate is recomputed (and the previous
    /// resolve cancelled).
    private var estimateKey: String {
        [
            viewModel.university.id, viewModel.faculty.id, viewModel.department.id,
            viewModel.lesson.name, viewModel.examName.id, String(viewModel.year),
        ].joined(separator: "|")
    }

    /// Whether every level needed to classify the submission has been chosen.
    private var isPlacementComplete: Bool {
        ![
            viewModel.university.name, viewModel.faculty.name, viewModel.department.name,
            viewModel.lesson.name, viewModel.examName.name,
        ].contains(where: \.isEmpty)
    }

    /// A row that pushes the bundled catalog picker (list-only) for `identifier` and shows the current value.
    private func catalogRow(
        title: LocalizedStringKey,
        selection: Binding<CatalogSelection>,
        options: [CatalogItem],
        identifier: String
    ) -> some View {
        let value = selection.wrappedValue.name
        return NavigationLink {
            CatalogPickerView(
                title: title,
                options: options,
                accessibilityPrefix: identifier,
                selection: selection,
                allowsCustom: false
            )
        } label: {
            LabeledContent(title) {
                Text(value.isEmpty ? String(localized: "Seç") : value)
                    .foregroundStyle(value.isEmpty ? .secondary : .primary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .disabled(viewModel.isWorking)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(Text(value))
    }
}

// MARK: - Files & rewards

private extension AddExamScreen {
    /// Loads the picked photos' data on a background task, then hands them to the view model to transcode.
    func loadImages(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            var data: [Data] = []
            for item in items {
                if let bytes = try? await item.loadTransferable(type: Data.self) {
                    data.append(bytes)
                }
            }
            photoSelection = []
            await viewModel.addImages(data)
        }
    }

    private func importPDF(_ result: Result<URL, any Error>) {
        guard case let .success(url) = result else { return }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            viewModel.reportFileReadFailure()
            return
        }
        viewModel.setPDF(data)
    }

    /// Keeps the reward config in step with the remote values for the screen's lifetime.
    private func observeRewards() async {
        for await config in rewardsConfigReader.rewardsChanges() {
            rewardsConfig = config
        }
    }

    /// Re-estimates the novelty tier for the current placement against the archive. Clears it while the
    /// placement is incomplete; a superseded resolve leaves the tier to the newer one.
    private func updateEstimate() async {
        guard isPlacementComplete else {
            estimatedTier = nil
            return
        }
        do {
            estimatedTier = try await resolver.tier(of: SubmissionLocation(
                university: viewModel.university.name,
                faculty: viewModel.faculty.name,
                department: viewModel.department.name,
                lesson: viewModel.lesson.name,
                examName: viewModel.examName.name,
                year: viewModel.year
            ))
        } catch is CancellationError {
            // A newer resolve superseded this one; leave the tier to it.
        } catch {
            estimatedTier = nil
        }
    }
}

#if DEBUG
#Preview("Sınav Ekle") {
    AddExamView()
        .environment(AppEnvironment.mock())
}
#endif

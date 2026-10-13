import SwiftUI

/// Picks the course (`ders`) for a submission. Lists the real archive courses for the chosen university's
/// matching department — resolved against the archive catalog by name, since the path is picked from the
/// bundled profile lists, not the archive — and offers a "Farklı ders ekle" option to type a course the
/// archive does not have yet. Pushed onto the add-exam form's navigation stack; choosing sets the binding and
/// pops back.
struct LessonPickerView: View {
    let university: String
    let department: String
    @Binding var selection: CatalogSelection

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        LessonPickerScreen(
            university: university,
            department: department,
            repository: environment.repository,
            selection: $selection
        )
    }
}

private struct LessonPickerScreen: View {
    @State private var viewModel: LessonPickerViewModel
    @Binding var selection: CatalogSelection
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var isAddingCustom = false
    @State private var customName = ""

    init(
        university: String,
        department: String,
        repository: any ArchiveRepository,
        selection: Binding<CatalogSelection>
    ) {
        _viewModel = State(initialValue: LessonPickerViewModel(
            university: university,
            department: department,
            repository: repository
        ))
        _selection = selection
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Ders ara", text: $query)
                        .accessibilityIdentifier("lessonPicker.search")
                }
            }

            Section("Mevcut Dersler") {
                coursesContent
            }

            Section {
                Button {
                    customName = query.trimmingCharacters(in: .whitespacesAndNewlines)
                    isAddingCustom = true
                } label: {
                    Label("Farklı ders ekle", systemImage: "plus.circle")
                }
                .accessibilityIdentifier("lessonPicker.addCustom")
            } footer: {
                Text("Dersin listede yoksa, adını yazarak ekleyebilirsin.")
            }
        }
        .navigationTitle("Ders")
        .navigationBarTitleDisplayMode(.inline)
        .autocorrectionDisabled()
        .task { await viewModel.loadIfNeeded() }
        .alert("Ders Ekle", isPresented: $isAddingCustom) {
            TextField("Ders adı", text: $customName)
            Button("Ekle") { chooseCustom() }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Eklemek istediğin dersin adını yaz.")
        }
    }

    @ViewBuilder
    private var coursesContent: some View {
        switch viewModel.state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView()
                Text("Dersler yükleniyor…").foregroundStyle(.secondary)
            }
        case let .failed(message):
            VStack(alignment: .leading, spacing: 8) {
                Text(message).foregroundStyle(.secondary)
                Button("Tekrar dene") { Task { await viewModel.load() } }
            }
        case .loaded:
            let matches = viewModel.courses(matching: query)
            if matches.isEmpty {
                Text(query.isEmpty
                    ? "Bu bölüm için arşivde kayıtlı ders yok. Aşağıdan ekleyebilirsin."
                    : "Aramanla eşleşen ders yok.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(matches) { item in
                    Button {
                        choose(CatalogSelection(name: item.name, id: Slug.make(item.name), isCustom: false))
                    } label: {
                        HStack {
                            Text(item.name).foregroundStyle(.primary)
                            Spacer()
                            if isSelected(item.name) {
                                Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
                            }
                        }
                    }
                    .accessibilityIdentifier("lessonPicker.option")
                }
            }
        }
    }

    private func isSelected(_ name: String) -> Bool {
        !selection.isEmpty && !selection.isCustom && selection.name == name
    }

    private func choose(_ newSelection: CatalogSelection) {
        selection = newSelection
        dismiss()
    }

    private func chooseCustom() {
        let selection = CatalogSelection.custom(customName)
        guard !selection.name.isEmpty else { return }
        choose(selection)
    }
}

/// Loads the archive courses under a department identified by its (bundled-list) display names.
@Observable
final class LessonPickerViewModel {
    private(set) var state: Loadable<[ArchiveItem]> = .loading

    @ObservationIgnored private let university: String
    @ObservationIgnored private let department: String
    @ObservationIgnored private let repository: any ArchiveRepository
    @ObservationIgnored private var hasLoaded = false

    init(university: String, department: String, repository: any ArchiveRepository) {
        self.university = university
        self.department = department
        self.repository = repository
    }

    /// The loaded courses whose names contain the search query; empty unless loaded.
    func courses(matching query: String) -> [ArchiveItem] {
        guard let items = state.value else { return [] }
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return items }
        return items.filter { ArchiveNameMatch.contains($0.name, needle) }
    }

    /// Loads once per screen; a cancelled load is retried on reappearance.
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        await load()
    }

    func load() async {
        state = .loading
        do {
            guard let departmentPath = try await resolveDepartmentPath() else {
                // The bundled path has no match in the archive: only free text is offered.
                state = .loaded([])
                return
            }
            state = .loaded(try await repository.items(at: departmentPath))
        } catch {
            guard !Self.isCancellation(error) else {
                hasLoaded = false
                return
            }
            state = .failed(message: error.userMessage)
        }
    }

    /// Finds the archive department matching the profile's university and department names. The university must
    /// match (the archive holds only a handful), but the department is searched across every faculty of that
    /// university — the bundled profile's faculty name does not necessarily match the archive's faculty name,
    /// so matching the faculty too would wrongly hide an existing department's courses. Returns `nil` when the
    /// university or the department has no match.
    private func resolveDepartmentPath() async throws -> ArchivePath? {
        guard !university.isEmpty, !department.isEmpty else { return nil }

        let universities = try await repository.items(at: .root)
        guard let universityMatch = universities.first(where: { ArchiveNameMatch.matches($0.name, university) }) else {
            return nil
        }

        let faculties = try await repository.items(at: universityMatch.path)
        for faculty in faculties {
            let departments = try await repository.items(at: faculty.path)
            if let match = departments.first(where: { ArchiveNameMatch.matchesDepartment(archive: $0.name, profile: department) }) {
                return match.path
            }
        }
        return nil
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }
}

/// Turkish-insensitive name matching for aligning bundled-list names with archive catalog names: case- and
/// diacritic-insensitive, dotted and dotless i alike (the same folding the archive search uses).
enum ArchiveNameMatch {
    private static let turkish = Locale(identifier: "tr_TR")

    /// Whether `lhs` and `rhs` are the same name after folding.
    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        key(for: lhs) == key(for: rhs)
    }

    /// Whether the archive department `archive` is the one the bundled `profile` name refers to, tolerating the
    /// archive's trailing academic suffix (so "MATEMATİK BÖLÜMÜ" matches the bundled "Matematik", while
    /// "MATEMATİK MÜHENDİSLİĞİ" — which keeps a distinct word — does not).
    static func matchesDepartment(archive: String, profile: String) -> Bool {
        departmentKey(for: archive) == departmentKey(for: profile)
    }

    /// Whether `haystack` contains `needle` after folding (for search).
    static func contains(_ haystack: String, _ needle: String) -> Bool {
        key(for: haystack).contains(key(for: needle))
    }

    private static func key(for text: String) -> String {
        text.lowercased(with: turkish)
            .replacingOccurrences(of: "ı", with: "i")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// A folded key with a trailing " bölümü" / " bölüm" dropped, so departments compare without the archive's
    /// suffix. Only a whole trailing word is removed, never a word stem.
    private static func departmentKey(for text: String) -> String {
        let key = key(for: text)
        for suffix in [" bolumu", " bolum"] where key.hasSuffix(suffix) {
            return String(key.dropLast(suffix.count))
        }
        return key
    }
}

#if DEBUG
#Preview("Ders Seçici") {
    @Previewable @State var selection = CatalogSelection.empty
    return NavigationStack {
        LessonPickerView(
            university: "BOZOK ÜNİVERSİTESİ",
            department: "BİLGİSAYAR MÜHENDİSLİĞİ",
            selection: $selection
        )
    }
    .environment(AppEnvironment.mock())
}
#endif

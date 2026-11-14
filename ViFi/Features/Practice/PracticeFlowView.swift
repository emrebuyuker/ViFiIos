import SwiftUI

/// The "Sınava gir" row at the top of a course's exam list. Only built once the course's index has questions
/// (see `PracticeEntryViewModel`); opens the setup + session flow in a sheet.
struct PracticeStartSection: View {
    let index: PracticePoolIndex
    let courseId: String

    @Environment(AppEnvironment.self) private var environment
    @State private var isPresented = false

    var body: some View {
        Section {
            Button {
                isPresented = true
            } label: {
                HStack(spacing: 12) {
                    IconBadge(systemName: "play.circle.fill", size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Sınava gir")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("Bu dersin soruları arasından soru çöz")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("practice.start")
        }
        .sheet(isPresented: $isPresented) {
            PracticeFlowView(
                viewModel: PracticeSetupViewModel(
                    index: index,
                    courseId: courseId,
                    universityId: knownUniversityId
                )
            )
        }
    }

    /// The profile's university id, unless the user typed a university that is not on the list (its id would not
    /// match any pool).
    private var knownUniversityId: String? {
        guard let profile = environment.profile.profile, !profile.universityIsCustom else { return nil }
        return profile.universityId
    }
}

private enum PracticeRoute: Hashable {
    case scopes(ExamType)
    case session(PracticeSelection)
}

/// The sheet: exam type, then scope, then the session. "Bitir" closes the whole sheet.
struct PracticeFlowView: View {
    let viewModel: PracticeSetupViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var environment
    @State private var path: [PracticeRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            PracticeTypeListView(rows: viewModel.typeRows) { type in
                path.append(.scopes(type))
            }
            .navigationTitle("Sınav Türü")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }
                        .accessibilityIdentifier("practice.close")
                }
            }
            .navigationDestination(for: PracticeRoute.self) { route in
                switch route {
                case let .scopes(type):
                    PracticeScopeListView(type: type, rows: viewModel.scopeRows(for: type)) { scope in
                        path.append(.session(viewModel.selection(type: type, scope: scope)))
                    }
                case let .session(selection):
                    PracticeSessionView(
                        viewModel: PracticeSessionViewModel(
                            selection: selection,
                            service: environment.practiceService,
                            analytics: environment.analytics
                        ),
                        onFinish: { dismiss() }
                    )
                }
            }
        }
        .onAppear { environment.analytics.track(.screenView(name: "PracticeSetup")) }
    }
}

// MARK: - Steps

private struct PracticeTypeListView: View {
    let rows: [PracticeSetupViewModel.TypeRow]
    let onSelect: (ExamType) -> Void

    var body: some View {
        List {
            Section {
                ForEach(rows) { row in
                    Button { onSelect(row.type) } label: {
                        PracticeChoiceRow(title: row.type.practiceTitle, count: row.count)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("practice.type.\(row.type.rawValue)")
                }
            } header: {
                Text("Hangi sınav türünden soru çözmek istersin?")
                    .textCase(nil)
            }
        }
        .accessibilityIdentifier("practice.types")
    }
}

private struct PracticeScopeListView: View {
    let type: ExamType
    let rows: [PracticeSetupViewModel.ScopeRow]
    let onSelect: (PracticeScope) -> Void

    var body: some View {
        List {
            Section {
                ForEach(rows) { row in
                    Button { onSelect(row.scope) } label: {
                        PracticeChoiceRow(title: row.scope.title, count: row.count)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("practice.scope.\(row.scope.rawValue)")
                }
            } header: {
                Text("Sorular nereden gelsin?")
                    .textCase(nil)
            }
        }
        .navigationTitle(type.practiceTitle)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("practice.scopes")
    }
}

/// A list row with a title, its question count and a chevron; one VoiceOver element.
private struct PracticeChoiceRow: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 8)
            Text("\(count) soru")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private extension PracticeScope {
    var title: String {
        switch self {
        case .course: "Bu ders"
        case .university: "Üniversitem"
        case .turkey: "Türkiye geneli"
        }
    }
}

#if DEBUG
#Preview("Sınava gir") {
    PracticeFlowView(
        viewModel: PracticeSetupViewModel(
            index: PracticePoolIndex(
                subjectId: "topoloji-1",
                name: "Topoloji 1",
                types: [.final: ["c-TOPOLOJİ 1": 3, "u-bogazici-universitesi": 2, "tr": 3], .vize: ["tr": 1]]
            ),
            courseId: "TOPOLOJİ 1",
            universityId: "bogazici-universitesi"
        )
    )
    .environment(AppEnvironment.mock())
}
#endif

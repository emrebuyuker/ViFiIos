import SwiftUI

/// The admin's subject list (P5): every country-wide course identity with its course and question counts, a search,
/// and an "Olası eşleşme" hint on single-university subjects whose name closely matches another subject.
struct SubjectMappingView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        SubjectMappingScreen(service: environment.subjectMappingService)
            .onAppear { environment.analytics.track(.screenView(name: "SubjectMapping")) }
    }
}

private struct SubjectMappingScreen: View {
    @State private var viewModel: SubjectMappingViewModel

    init(service: any SubjectMappingServicing) {
        _viewModel = State(initialValue: SubjectMappingViewModel(service: service))
    }

    var body: some View {
        content
            .navigationTitle("Ders eşleme")
            .navigationBarTitleDisplayMode(.inline)
            .animation(.smooth, value: viewModel.state)
            .task { await viewModel.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            LoadingStateView(title: "Dersler yükleniyor…")
        case let .failed(message):
            ErrorStateView(message: message) { Task { await viewModel.refresh() } }
        case let .loaded(subjects):
            if subjects.isEmpty {
                EmptyStateView(
                    title: "Ders yok",
                    systemImage: "books.vertical",
                    message: "Yapılandırılmış bir sınav yayınlanınca dersi burada görünür."
                )
            } else {
                list
            }
        }
    }

    private var list: some View {
        List {
            if let error = viewModel.actionError {
                Section {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("subjects.error")
                }
            }
            Section {
                ForEach(viewModel.filteredSubjects) { subject in
                    NavigationLink {
                        SubjectDetailView(subjectId: subject.id, viewModel: viewModel)
                    } label: {
                        SubjectRow(subject: subject, possibleMatch: viewModel.possibleMatch(for: subject.id))
                    }
                    .accessibilityIdentifier("subjects.row.\(subject.id)")
                }
            } footer: {
                Text("\(viewModel.filteredSubjects.count) ders")
            }
        }
        .accessibilityIdentifier("subjects.list")
        .searchable(text: $viewModel.searchText, prompt: "Ders ara")
        .refreshable { await viewModel.refresh() }
    }
}

/// One subject: its name, how many courses and questions it holds, and the "Olası eşleşme" hint.
private struct SubjectRow: View {
    let subject: AdminSubject
    let possibleMatch: AdminSubject?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(subject.name)
                .font(.headline)
            Text("\(subject.courseCount) ders · \(subject.questionCount) soru")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let possibleMatch {
                Label("Olası eşleşme: \(possibleMatch.name)", systemImage: "arrow.triangle.merge")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("subjects.possibleMatch")
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Ders eşleme") {
    NavigationStack {
        SubjectMappingView()
    }
    .environment(AppEnvironment.mock())
    .environment(Router())
}
#endif

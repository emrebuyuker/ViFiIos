import SwiftUI

/// Picks the exam a notification links to by walking the archive — university › faculty › department › course ›
/// exam — with the same lists and search as browsing it. Only an exam with files can be picked; the server fills in
/// its path and names from the published exam (`sendNotification`).
struct NotificationExamPickerView: View {
    let repository: any ArchiveRepository
    let onPick: (ArchiveItem) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            NotificationExamPickerList(path: .root, repository: repository, onPick: pick)
                .navigationDestination(for: ArchivePath.self) { path in
                    NotificationExamPickerList(path: path, repository: repository, onPick: pick)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Vazgeç") { dismiss() }
                            .accessibilityIdentifier("notificationComposer.exam.cancel")
                    }
                }
        }
    }

    private func pick(_ exam: ArchiveItem) {
        onPick(exam)
        dismiss()
    }
}

/// One level of the picker: the entries under `path`, searchable; exams are picked, everything else drills down.
private struct NotificationExamPickerList: View {
    let onPick: (ArchiveItem) -> Void

    @State private var viewModel: BrowseViewModel

    init(path: ArchivePath, repository: any ArchiveRepository, onPick: @escaping (ArchiveItem) -> Void) {
        self.onPick = onPick
        _viewModel = State(initialValue: BrowseViewModel(path: path, repository: repository))
    }

    private var listedLevel: ArchiveLevel {
        viewModel.path.childLevel ?? .exam
    }

    var body: some View {
        List(viewModel.visibleItems) { item in
            row(for: item)
                .accessibilityIdentifier("notificationComposer.exam.row.\(item.name)")
        }
        .listStyle(.insetGrouped)
        .overlay { stateOverlay }
        .navigationTitle(viewModel.path.displayName ?? String(localized: "Sınav Seç"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $viewModel.searchText, prompt: listedLevel.searchPrompt)
        .task {
            if viewModel.state.isLoading {
                await viewModel.load()
            }
        }
    }

    @ViewBuilder
    private func row(for item: ArchiveItem) -> some View {
        if item.level == .exam {
            Button {
                onPick(item)
            } label: {
                ArchiveRow(item: item)
            }
            .tint(.primary)
            // An exam without files has nothing to open.
            .disabled(item.exam == nil)
        } else {
            NavigationLink(value: item.path) {
                ArchiveRow(item: item)
            }
        }
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch viewModel.state {
        case .loading:
            LoadingStateView()
        case let .failed(message):
            ErrorStateView(message: message) { Task { await viewModel.load() } }
        case let .loaded(items) where items.isEmpty:
            EmptyStateView(title: listedLevel.emptyListTitle, systemImage: listedLevel.symbolName, message: nil)
        case .loaded where viewModel.visibleItems.isEmpty:
            SearchEmptyStateView(query: viewModel.searchQuery)
        case .loaded:
            EmptyView()
        }
    }
}

#if DEBUG
#Preview("Sınav Seç") {
    NotificationExamPickerView(repository: MockArchiveRepository()) { _ in }
        .environment(AppEnvironment.mock())
}
#endif

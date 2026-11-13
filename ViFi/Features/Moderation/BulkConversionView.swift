import SwiftUI

/// Admin bulk conversion (K12b): pick a course or a whole department, pick the AI provider, read the dry-run
/// estimate next to the month's $50 gauge, and confirm to queue the unconverted exams.
struct BulkConversionView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        BulkConversionScreen(service: environment.conversionService)
    }
}

private struct BulkConversionScreen: View {
    @State private var viewModel: BulkConversionViewModel
    @State private var scopeName: String?
    @State private var isPickingScope = false
    @State private var isConfirming = false

    init(service: any ExamConversionServicing) {
        _viewModel = State(initialValue: BulkConversionViewModel(service: service))
    }

    var body: some View {
        Form {
            Section {
                AIUsageGauge(usage: viewModel.usage)
            }
            Section("Kapsam") {
                Button {
                    isPickingScope = true
                } label: {
                    HStack {
                        Text(scopeName ?? "Ders ya da bölüm seç")
                            .foregroundStyle(scopeName == nil ? .secondary : .primary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.tertiary)
                    }
                }
                .accessibilityIdentifier("bulk.scope")
            }
            Section {
                AIProviderChoice(selection: $viewModel.provider)
            } header: {
                Text("Model")
            } footer: {
                Text("Her toplu işte modeli sen seçersin; varsayılan yok.")
            }
            Section {
                Button {
                    Task { await viewModel.estimate() }
                } label: {
                    HStack {
                        Label("Tahmini hesapla", systemImage: "function")
                        Spacer()
                        if viewModel.phase == .estimating { ProgressView() }
                    }
                }
                .disabled(!viewModel.canEstimate)
                .accessibilityIdentifier("bulk.estimate")
            } footer: {
                Text("Hesaplama hiçbir iş başlatmaz; yalnızca sınav sayısını ve tahmini maliyeti gösterir.")
            }
            resultSection
            if let message = viewModel.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("bulk.error")
                }
            }
        }
        .navigationTitle("Toplu dönüştür")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.smooth, value: viewModel.phase)
        .task { await viewModel.loadUsage() }
        .sheet(isPresented: $isPickingScope) {
            BulkScopePicker { scope, name in
                viewModel.scope = scope
                scopeName = name
                isPickingScope = false
            }
        }
        .alert("Kuyruğa alınsın mı?", isPresented: $isConfirming) {
            Button("Kuyruğa al") { Task { await viewModel.confirm() } }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    @ViewBuilder
    private var resultSection: some View {
        switch viewModel.phase {
        case let .estimated(estimate):
            Section("Tahmin") {
                LabeledContent("Dönüştürülecek sınav", value: "\(estimate.examCount)")
                LabeledContent("Tahmini maliyet", value: estimate.estimatedCostUsd.usd)
                if viewModel.estimateExceedsBudget {
                    Label("Bu ayın 50 $ sınırını aşabilir; sunucu aşan işi reddeder.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("bulk.overBudget")
                }
                Button {
                    isConfirming = true
                } label: {
                    Label("Kuyruğa al", systemImage: "tray.and.arrow.down")
                }
                .disabled(estimate.examCount == 0)
                .accessibilityIdentifier("bulk.confirm")
            }
        case .queueing:
            Section { ProgressView("Kuyruğa alınıyor…") }
        case let .queued(result):
            Section {
                Label("\(result.examCount) sınav kuyruğa alındı.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("bulk.queued")
            }
        case .idle, .estimating:
            EmptyView()
        }
    }

    private var confirmMessage: String {
        guard case let .estimated(estimate) = viewModel.phase else { return "" }
        return String(localized: "\(estimate.examCount) sınav, tahmini \(estimate.estimatedCostUsd.usd) ile yapay zekâya gönderilecek.")
    }
}

/// Browses the archive down to a department (all its exams) or one of its courses and reports the choice.
private struct BulkScopePicker: View {
    let onSelect: (BulkConversionScope, String) -> Void

    var body: some View {
        NavigationStack {
            BulkScopeLevel(path: .root, onSelect: onSelect)
        }
    }
}

private struct BulkScopeLevel: View {
    let path: ArchivePath
    let onSelect: (BulkConversionScope, String) -> Void

    @Environment(AppEnvironment.self) private var environment
    @State private var items: Loadable<[ArchiveItem]> = .loading

    var body: some View {
        Group {
            switch items {
            case .loading:
                LoadingStateView(title: "Yükleniyor…")
            case let .failed(message):
                ErrorStateView(message: message) { Task { await load() } }
            case let .loaded(entries):
                List {
                    if path.depth == 3, let departmentId = path.components.last {
                        Section {
                            Button("Tüm bölümü seç") {
                                onSelect(.department(id: departmentId), path.displayNames.joined(separator: " › "))
                            }
                            .accessibilityIdentifier("bulk.pick.department")
                        }
                    }
                    Section(path.isRoot ? "Üniversiteler" : path.displayName ?? "") {
                        ForEach(entries) { entry in
                            row(entry)
                        }
                    }
                }
            }
        }
        .navigationTitle(path.displayName ?? "Kapsam seç")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    @ViewBuilder
    private func row(_ entry: ArchiveItem) -> some View {
        if entry.level == .lesson, let courseId = entry.path.components.last {
            Button(entry.name) {
                onSelect(.course(id: courseId), entry.path.displayNames.joined(separator: " › "))
            }
            .foregroundStyle(.primary)
            .accessibilityIdentifier("bulk.pick.course.\(courseId)")
        } else if entry.level.rawValue <= ArchiveLevel.department.rawValue {
            NavigationLink(entry.name) {
                BulkScopeLevel(path: entry.path, onSelect: onSelect)
            }
        }
    }

    private func load() async {
        do {
            items = .loaded(try await environment.repository.items(at: path))
        } catch is CancellationError {
            return
        } catch {
            items = .failed(message: error.userMessage)
        }
    }
}

#if DEBUG
#Preview("Toplu dönüştür") {
    NavigationStack {
        BulkConversionView()
    }
    .environment(AppEnvironment.mock())
}
#endif

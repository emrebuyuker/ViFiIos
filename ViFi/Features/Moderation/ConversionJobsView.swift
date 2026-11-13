import SwiftUI

/// The admin's job list of one kind: "Hazır sınavlar" (drafts waiting for the second approval, each opening the
/// review) or "Başarısız işler" (with "Tekrar başlat" and a provider choice).
struct ConversionJobsView: View {
    let kind: ConversionListKind

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        ConversionJobsScreen(kind: kind, service: environment.conversionService)
    }
}

private struct ConversionJobsScreen: View {
    @State private var viewModel: ConversionJobsViewModel
    @State private var restarting: ExamConversion?

    init(kind: ConversionListKind, service: any ExamConversionServicing) {
        _viewModel = State(initialValue: ConversionJobsViewModel(kind: kind, service: service))
    }

    var body: some View {
        content
            .navigationTitle(viewModel.kind == .ready ? "Hazır sınavlar" : "Başarısız işler")
            .navigationBarTitleDisplayMode(.inline)
            .animation(.smooth, value: viewModel.state)
            .task { await viewModel.loadIfNeeded() }
            .onAppear { Task { await viewModel.refreshIfLoaded() } }
            .aiProviderDialog("Hangi modelle yeniden başlatılsın?", isPresented: isPickingProvider) { provider in
                guard let job = restarting else { return }
                Task { await viewModel.restart(job, provider: provider) }
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            LoadingStateView(title: "İşler yükleniyor…")
        case let .failed(message):
            ErrorStateView(message: message) { Task { await viewModel.refresh() } }
        case let .loaded(jobs):
            if jobs.isEmpty {
                EmptyStateView(
                    title: viewModel.kind == .ready ? "Hazır sınav yok" : "Başarısız iş yok",
                    systemImage: "tray",
                    message: viewModel.kind == .ready
                        ? "Yapay zekâ bir sınavı bitirince burada incelemeye hazır görünür."
                        : "Tüm işler sorunsuz ilerliyor."
                )
            } else {
                list(jobs)
            }
        }
    }

    private func list(_ jobs: [ExamConversion]) -> some View {
        List {
            if let error = viewModel.actionError {
                Section {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("conversion.list.error")
                }
            }
            Section {
                ForEach(jobs) { job in
                    row(job)
                }
            }
        }
        .accessibilityIdentifier(viewModel.kind == .ready ? "conversion.ready.list" : "conversion.failed.list")
        .refreshable { await viewModel.refresh() }
    }

    @ViewBuilder
    private func row(_ job: ExamConversion) -> some View {
        if viewModel.kind == .ready {
            NavigationLink {
                ConversionReviewView(job: job)
            } label: {
                ConversionJobRow(job: job)
            }
            .accessibilityIdentifier("conversion.row.\(job.id)")
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ConversionJobRow(job: job)
                Button {
                    restarting = job
                } label: {
                    Label("Tekrar başlat", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isWorking)
                .accessibilityIdentifier("conversion.restart.\(job.id)")
            }
            .padding(.vertical, 4)
        }
    }

    private var isPickingProvider: Binding<Bool> {
        Binding(get: { restarting != nil }, set: { if !$0 { restarting = nil } })
    }
}

/// One job: the exam, where it belongs, the provider and cost, and the last error of a failed run.
private struct ConversionJobRow: View {
    let job: ExamConversion

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(systemName: job.kind == .images ? "photo.on.rectangle.angled" : "doc.fill")
            VStack(alignment: .leading, spacing: 3) {
                Text(job.examTitle)
                    .font(.headline)
                if !job.placementPath.isEmpty {
                    Text(job.placementPath)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !job.providerAndCost.isEmpty {
                    Text(job.providerAndCost)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = job.error, job.status == .failed {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#if DEBUG
#Preview("Hazır sınavlar") {
    NavigationStack {
        ConversionJobsView(kind: .ready)
    }
    .environment(AppEnvironment.mock())
}

#Preview("Başarısız işler") {
    NavigationStack {
        ConversionJobsView(kind: .failed)
    }
    .environment(AppEnvironment.mock())
}
#endif

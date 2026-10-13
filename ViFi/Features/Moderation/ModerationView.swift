import SwiftUI

/// The admin moderation queue: the submissions awaiting review, each opening a detail where it is previewed and
/// approved or rejected. Reachable only from the account screen, and only by an admin.
struct ModerationView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        ModerationScreen(service: environment.moderationService)
            .onAppear { environment.analytics.track(.screenView(name: "Moderation")) }
    }
}

private struct ModerationScreen: View {
    @State private var viewModel: ModerationViewModel

    init(service: any ModerationServicing) {
        _viewModel = State(initialValue: ModerationViewModel(service: service))
    }

    var body: some View {
        content
            .navigationTitle("Moderasyon")
            .navigationBarTitleDisplayMode(.inline)
            .animation(.smooth, value: viewModel.state)
            .task { await viewModel.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            LoadingStateView(title: "Gönderimler yükleniyor…")
        case let .failed(message):
            ErrorStateView(message: message) { Task { await viewModel.refresh() } }
        case let .loaded(records):
            if records.isEmpty {
                EmptyStateView(
                    title: "Bekleyen gönderim yok",
                    systemImage: "tray",
                    message: "Yeni gönderimler onay için burada görünür."
                )
            } else {
                List {
                    Section {
                        ForEach(records) { record in
                            NavigationLink {
                                ModerationDetailView(record: record, viewModel: viewModel)
                            } label: {
                                ModerationRow(record: record)
                            }
                            .accessibilityIdentifier("moderation.row.\(record.id)")
                        }
                    } footer: {
                        Text("\(records.count) gönderim onay bekliyor.")
                    }
                }
                .accessibilityIdentifier("moderation.list")
                .refreshable { await viewModel.refresh() }
            }
        }
    }
}

/// One row of the moderation queue: the exam, its place in the archive, and its size.
private struct ModerationRow: View {
    let record: ExamSubmissionRecord

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(systemName: record.kind == .images ? "photo.on.rectangle.angled" : "doc.fill")
            VStack(alignment: .leading, spacing: 3) {
                Text(record.exam)
                    .font(.headline)
                Text("\(record.lesson) · \(record.department)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(record.university)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(record.files.count) \(record.kind == .images ? "görsel" : "PDF")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Moderasyon") {
    NavigationStack {
        ModerationView()
    }
    .environment(AppEnvironment.mock())
    .environment(Router())
}
#endif

import SwiftUI

/// The admin moderation queue: the submissions awaiting review, each opening a detail where it is previewed and
/// approved or rejected. Reachable only from the account screen, and only by an admin.
struct ModerationView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        ModerationScreen(service: environment.moderationService, submitterReader: environment.submitterReader)
            .onAppear { environment.analytics.track(.screenView(name: "Moderation")) }
    }
}

private struct ModerationScreen: View {
    @State private var viewModel: ModerationViewModel

    init(service: any ModerationServicing, submitterReader: any SubmitterProfileReading) {
        _viewModel = State(initialValue: ModerationViewModel(service: service, submitterReader: submitterReader))
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
            List {
                conversionSection
                Section {
                    if records.isEmpty {
                        Text("Bekleyen gönderim yok. Yeni gönderimler onay için burada görünür.")
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("moderation.empty")
                    }
                    ForEach(records) { record in
                        NavigationLink {
                            ModerationDetailView(record: record, viewModel: viewModel)
                        } label: {
                            ModerationRow(record: record, viewModel: viewModel)
                        }
                        .accessibilityIdentifier("moderation.row.\(record.id)")
                    }
                } header: {
                    Text("Bekleyen gönderimler")
                } footer: {
                    if !records.isEmpty {
                        Text("\(records.count) gönderim onay bekliyor.")
                    }
                }
            }
            .accessibilityIdentifier("moderation.list")
            .refreshable { await viewModel.refresh() }
        }
    }

    /// The 4.2.0 AI conversion tools: drafts to review, failed jobs and the bulk queue.
    private var conversionSection: some View {
        Section("Yapılandırılmış sınavlar") {
            NavigationLink {
                ConversionJobsView(kind: .ready)
            } label: {
                Label("Hazır sınavlar", systemImage: "checkmark.seal")
            }
            .accessibilityIdentifier("moderation.ready")
            NavigationLink {
                ConversionJobsView(kind: .failed)
            } label: {
                Label("Başarısız işler", systemImage: "exclamationmark.triangle")
            }
            .accessibilityIdentifier("moderation.failed")
            NavigationLink {
                BulkConversionView()
            } label: {
                Label("Toplu dönüştür", systemImage: "square.stack.3d.up")
            }
            .accessibilityIdentifier("moderation.bulk")
            NavigationLink {
                SubjectMappingView()
            } label: {
                Label("Ders eşleme", systemImage: "arrow.triangle.merge")
            }
            .accessibilityIdentifier("moderation.subjects")
        }
    }
}

/// One row of the moderation queue: the exam, its place in the archive, and its size.
private struct ModerationRow: View {
    let record: ExamSubmissionRecord
    let viewModel: ModerationViewModel

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
                submitterLines
            }
            Spacer()
            Text("\(record.files.count) \(record.kind == .images ? "görsel" : "PDF")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .task { await viewModel.loadSubmitter(uid: record.ownerId) }
    }

    /// "Gönderen: Ad Soyad" plus "Üniversite · Bölüm", or a quiet placeholder / non-blocking error.
    @ViewBuilder
    private var submitterLines: some View {
        switch viewModel.submitters[record.ownerId] {
        case let .loaded(info):
            VStack(alignment: .leading, spacing: 1) {
                Text("Gönderen: \(info.fullName)")
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Text(SubmitterSummary.affiliation(info))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .accessibilityIdentifier("moderation.submitter")
        case .missing:
            Text("Profil bulunamadı (hesap silinmiş olabilir)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier("moderation.submitter")
        case .failed:
            Text("Gönderen bilgisi yüklenemedi")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityIdentifier("moderation.submitter")
        case .loading, nil:
            Text("Gönderen yükleniyor…")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .redacted(reason: .placeholder)
        }
    }
}

/// Text helpers for the submitter shown in the queue.
nonisolated enum SubmitterSummary {
    /// "Üniversite · Bölüm", skipping whichever part is empty.
    static func affiliation(_ info: SubmitterInfo) -> String {
        [info.university, info.department].filter { !$0.isEmpty }.joined(separator: " · ")
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

import SwiftUI

/// The second approval of one ready job: the original pages (the protected preview) and the draft questions, with
/// per-question edit and regenerate (K8), the course mapping, "Yayınla", "Tümünü yeniden üret" (K14) and "Sınavı
/// iptal et". The draft shows Markdown/LaTeX as written; it is an admin-only review, the user screen renders it.
struct ConversionReviewView: View {
    let job: ExamConversion

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        ConversionReviewScreen(job: job, service: environment.conversionService)
    }
}

private struct ConversionReviewScreen: View {
    @State private var viewModel: ConversionReviewViewModel
    @State private var editing: ExamQuestion?
    @State private var regeneratingOrder: Int?
    @State private var isPickingProviderForAll = false
    @State private var isConfirmingPublish = false
    @State private var isConfirmingDiscard = false
    @Environment(\.dismiss) private var dismiss

    init(job: ExamConversion, service: any ExamConversionServicing) {
        _viewModel = State(initialValue: ConversionReviewViewModel(job: job, service: service))
    }

    var body: some View {
        content
            .navigationTitle(viewModel.job.examTitle)
            .navigationBarTitleDisplayMode(.inline)
            .animation(.smooth, value: viewModel.drafts)
            .task { await viewModel.loadIfNeeded() }
            .sheet(item: $editing) { question in
                QuestionEditorView(question: question) { edited in
                    await viewModel.save(edited) ? nil : (viewModel.errorMessage ?? "")
                }
            }
            .aiProviderDialog("Soru hangi modelle yeniden üretilsin?", isPresented: isPickingProviderForQuestion) { provider in
                guard let order = regeneratingOrder else { return }
                Task { await viewModel.regenerateQuestion(order: order, provider: provider) }
            }
            .aiProviderDialog("Tüm sınav hangi modelle yeniden üretilsin?", isPresented: $isPickingProviderForAll) { provider in
                Task { await viewModel.regenerateAll(provider: provider) }
            }
            .alert("Yayınlansın mı?", isPresented: $isConfirmingPublish) {
                Button("Yayınla") { Task { await viewModel.publish() } }
                Button("Vazgeç", role: .cancel) {}
            } message: {
                Text("Sorular tüm kullanıcılara açılır ve sınav yeni yapıya geçer.")
            }
            .alert("Sınav iptal edilsin mi?", isPresented: $isConfirmingDiscard) {
                Button("Sınavı iptal et", role: .destructive) { Task { await viewModel.discard() } }
                Button("Vazgeç", role: .cancel) {}
            } message: {
                Text("Taslak silinir ve sınav yapılandırılmaz. Gönderene verilen coin geri alınmaz.")
            }
            .alert(outcomeTitle, isPresented: outcomeBinding) {
                Button("Tamam") { dismiss() }
            } message: {
                Text(outcomeMessage)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.drafts {
        case .loading:
            LoadingStateView(title: "Taslak yükleniyor…")
        case let .failed(message):
            ErrorStateView(message: message) { Task { await viewModel.refresh() } }
        case let .loaded(questions):
            Form {
                infoSection
                if let message = viewModel.errorMessage, !message.isEmpty {
                    Section {
                        Label(message, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("conversion.review.error")
                    }
                }
                if let info = viewModel.infoMessage {
                    Section { Label(info, systemImage: "info.circle") }
                }
                Section("Sorular (\(questions.count))") {
                    ForEach(questions) { question in
                        DraftQuestionRow(
                            question: question,
                            isBusy: viewModel.isWorking,
                            onEdit: { editing = question },
                            onRegenerate: { regeneratingOrder = question.order }
                        )
                    }
                }
                subjectSection
                actionsSection
            }
            .accessibilityIdentifier("conversion.review")
            .refreshable { await viewModel.refresh() }
        }
    }

    private var infoSection: some View {
        Section {
            if !viewModel.job.placementPath.isEmpty {
                Text(viewModel.job.placementPath).font(.subheadline)
            }
            if !viewModel.job.providerAndCost.isEmpty {
                LabeledContent("Model ve maliyet", value: viewModel.job.providerAndCost)
            }
            if viewModel.needsReviewCount > 0 {
                Label("\(viewModel.needsReviewCount) soru dikkatli bakış istiyor", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            if !viewModel.job.files.isEmpty {
                NavigationLink {
                    SubmissionFilePreview(files: viewModel.job.files, kind: viewModel.job.kind)
                } label: {
                    Label("Orijinal sayfaları göster", systemImage: "eye")
                }
                .accessibilityIdentifier("conversion.review.original")
            }
        }
    }

    private var subjectSection: some View {
        Section {
            if let suggested = viewModel.job.suggestedSubjectName ?? viewModel.job.suggestedSubjectId {
                LabeledContent("Önerilen ders", value: suggested)
            }
            Picker("Ders eşlemesi", selection: $viewModel.subjectMode) {
                Text("Önerilen").tag(SubjectMode.suggested)
                Text("Mevcut kimlik").tag(SubjectMode.existing)
                Text("Yeni ders").tag(SubjectMode.new)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("conversion.review.subjectMode")
            switch viewModel.subjectMode {
            case .suggested:
                EmptyView()
            case .existing:
                TextField("Ders kimliği (subjectId)", text: $viewModel.subjectId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("conversion.review.subjectId")
            case .new:
                TextField("Yeni dersin adı", text: $viewModel.newSubjectName)
                    .accessibilityIdentifier("conversion.review.newSubject")
            }
        } header: {
            Text("Ders eşlemesi")
        } footer: {
            Text("Türkiye geneli soru havuzunun doğruluğu bu eşlemeye bağlı; ders adı farklı yazılmış olabilir.")
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                isConfirmingPublish = true
            } label: {
                HStack {
                    Label("Yayınla", systemImage: "checkmark.circle.fill")
                    Spacer()
                    if viewModel.isWorking { ProgressView() }
                }
            }
            .disabled(!viewModel.canPublish)
            .accessibilityIdentifier("conversion.review.publish")

            Button {
                isPickingProviderForAll = true
            } label: {
                Label("Tümünü yeniden üret", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isWorking)
            .accessibilityIdentifier("conversion.review.regenerateAll")

            Button(role: .destructive) {
                isConfirmingDiscard = true
            } label: {
                Label("Sınavı iptal et", systemImage: "xmark.circle")
                    .foregroundStyle(.red)
            }
            .disabled(viewModel.isWorking)
            .accessibilityIdentifier("conversion.review.discard")
        }
    }

    private var isPickingProviderForQuestion: Binding<Bool> {
        Binding(get: { regeneratingOrder != nil }, set: { if !$0 { regeneratingOrder = nil } })
    }

    private var outcomeBinding: Binding<Bool> {
        Binding(get: { viewModel.outcome != nil }, set: { _ in })
    }

    private var outcomeTitle: LocalizedStringKey {
        switch viewModel.outcome {
        case .published: "Yayınlandı"
        case .discarded: "İptal edildi"
        case .regenerating: "Yeniden üretiliyor"
        case nil: ""
        }
    }

    private var outcomeMessage: String {
        switch viewModel.outcome {
        case let .published(count): String(localized: "\(count) soru yayınlandı.")
        case .discarded: String(localized: "Sınav yapılandırılmayacak.")
        case .regenerating: String(localized: "Sınav yeniden üretiliyor; hazır olunca listede tekrar görünür.")
        case nil: ""
        }
    }
}

/// One draft question: its text, the answer and flags, with edit and regenerate actions.
private struct DraftQuestionRow: View {
    let question: ExamQuestion
    let isBusy: Bool
    let onEdit: () -> Void
    let onRegenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Soru \(question.label)").font(.headline)
                if question.needsReview {
                    Label("Kontrol et", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                if let confidence = question.confidence {
                    Text(confidence, format: .percent.precision(.fractionLength(0)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text(question.text)
                .font(.callout)
            ForEach(question.choices, id: \.self) { choice in
                Text("\(choice.label)) \(choice.text)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("Cevap: \(question.answer.choice.map { "\($0) — " } ?? "")\(question.answer.text)")
                .font(.footnote.weight(.medium))
            HStack {
                Button("Düzenle", systemImage: "pencil", action: onEdit)
                    .accessibilityIdentifier("conversion.question.edit.\(question.order)")
                Button("Yeniden üret", systemImage: "arrow.clockwise", action: onRegenerate)
                    .accessibilityIdentifier("conversion.question.regenerate.\(question.order)")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isBusy)
        }
        .padding(.vertical, 4)
    }
}

#if DEBUG
#Preview("Hazır sınav incelemesi") {
    NavigationStack {
        ConversionReviewView(job: MockExamConversionService.samples[0])
    }
    .environment(AppEnvironment.mock())
}
#endif

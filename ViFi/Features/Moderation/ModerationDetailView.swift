import SwiftUI

/// One submission under review: its place in the archive, a link to preview the files, and the approve / reject
/// actions. The first approval credits the owner and starts the AI conversion with the chosen provider;
/// rejecting records an optional reason.
struct ModerationDetailView: View {
    let record: ExamSubmissionRecord
    let viewModel: ModerationViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var environment
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var isConfirmingReject = false
    @State private var rejectReason = ""
    @State private var approval: ApprovalResult?
    @State private var duplicateExamId: String?

    var body: some View {
        Form {
            if duplicateExamId != nil {
                duplicateWarningSection
            }
            submitterSection
            detailsSection
            filesSection
            actionsSection

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("moderation.detail.error")
                }
            }
        }
        .navigationTitle("Gönderim")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.smooth, value: errorMessage)
        .animation(.smooth, value: duplicateExamId)
        .task { await viewModel.loadSubmitter(uid: record.ownerId) }
        .task { duplicateExamId = await viewModel.duplicateExamId(for: record) }
        .interactiveDismissDisabled(isWorking)
        .alert("Reddedilsin mi?", isPresented: $isConfirmingReject) {
            TextField("Sebep (isteğe bağlı)", text: $rejectReason)
            Button("Reddet", role: .destructive) { performReject() }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Bu gönderim arşive eklenmez ve coin verilmez.")
        }
        .alert("Onaylandı", isPresented: approvalBinding, presenting: approval) { _ in
            Button("Tamam") { dismiss() }
        } message: { result in
            Text(approvalMessage(result))
        }
    }

    // MARK: - Sections

    /// K22: the archive already has this exam; approving replaces its questions and pages at the second approval.
    private var duplicateWarningSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Label("Bu sınav arşivde zaten yüklü", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text("İkinci onayda bu sınavın soruları ve sayfaları bu gönderimle değiştirilir.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("moderation.duplicateWarning")
        }
    }

    /// Who submitted this exam: name and affiliation only, never the phone number. A failed or missing lookup
    /// is shown as a note and never blocks approving or rejecting.
    private var submitterSection: some View {
        Section("Gönderen") {
            switch viewModel.submitters[record.ownerId] {
            case let .loaded(info):
                Group {
                    detailRow("Ad Soyad", info.fullName)
                    if !info.university.isEmpty { detailRow("Üniversite", info.university) }
                    if !info.faculty.isEmpty { detailRow("Fakülte", info.faculty) }
                    if !info.department.isEmpty { detailRow("Bölüm", info.department) }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("moderation.detail.submitter")
            case .missing:
                Text("Profil bulunamadı (hesap silinmiş olabilir)")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("moderation.detail.submitter")
            case .failed:
                Text("Gönderen bilgisi yüklenemedi")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("moderation.detail.submitter")
            case .loading, nil:
                Text("Gönderen yükleniyor…")
                    .foregroundStyle(.tertiary)
                    .redacted(reason: .placeholder)
            }
        }
    }

    private var detailsSection: some View {
        Section("Gönderim") {
            detailRow("Üniversite", record.university)
            detailRow("Fakülte", record.faculty)
            detailRow("Bölüm", record.department)
            detailRow("Ders", record.lesson)
            detailRow("Sınav", record.exam)
            detailRow("Tür", record.kind.label)
            if let createdAt = record.createdAt {
                detailRow("Tarih", createdAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
    }

    private var filesSection: some View {
        Section {
            NavigationLink {
                SubmissionFilePreview(files: record.files, kind: record.kind)
            } label: {
                Label(
                    "Dosyaları incele (\(record.files.count) \(record.kind == .images ? "görsel" : "PDF"))",
                    systemImage: "eye"
                )
            }
            .disabled(isWorking)
            .accessibilityIdentifier("moderation.detail.preview")
        }
    }

    private var actionsSection: some View {
        Section {
            ForEach(AIProvider.allCases, id: \.self) { provider in
                Button {
                    performApprove(provider: provider)
                } label: {
                    HStack {
                        Label("Onayla · \(provider.displayName) ile ilerle", systemImage: "checkmark.circle.fill")
                        Spacer()
                        if isWorking {
                            ProgressView()
                        }
                    }
                }
                .disabled(isWorking)
                .accessibilityIdentifier("moderation.approve.\(provider.rawValue)")
            }

            Button(role: .destructive) {
                rejectReason = ""
                isConfirmingReject = true
            } label: {
                Label("Reddet", systemImage: "xmark.circle")
                    .foregroundStyle(.red)
            }
            .disabled(isWorking)
            .accessibilityIdentifier("moderation.detail.reject")
        } footer: {
            Text("Onaylarsan gönderene yenilik kademesine göre coin verilir; sayfalar seçtiğin yapay zekâ modeliyle "
                + "sorulara dönüştürülür. Hazır olunca Hazır sınavlar'dan inceleyip yayınlarsın.")
        }
    }

    private func detailRow(_ title: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent(title) {
            Text(value)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Actions

    private func performApprove(provider: AIProvider) {
        errorMessage = nil
        isWorking = true
        Task {
            let outcome = await viewModel.approve(record, provider: provider)
            isWorking = false
            switch outcome {
            case let .approved(result):
                approval = result
                environment.analytics.track(.submissionApproved(tier: result.tier))
            case let .failed(message):
                errorMessage = message
            }
        }
    }

    private func performReject() {
        errorMessage = nil
        isWorking = true
        let reason = rejectReason.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let message = await viewModel.reject(record, reason: reason.isEmpty ? nil : reason)
            isWorking = false
            if let message {
                errorMessage = message
            } else {
                environment.analytics.track(.submissionRejected)
                dismiss()
            }
        }
    }

    private var approvalBinding: Binding<Bool> {
        Binding(get: { approval != nil }, set: { if !$0 { approval = nil } })
    }

    private func approvalMessage(_ result: ApprovalResult) -> String {
        if result.coins > 0 {
            String(localized: "\(result.tier.label): gönderene \(result.coins) coin verildi. Sınav yapay zekâya gönderilecek.")
        } else {
            String(localized: "Gönderim onaylandı. Sınav yapay zekâya gönderilecek.")
        }
    }
}

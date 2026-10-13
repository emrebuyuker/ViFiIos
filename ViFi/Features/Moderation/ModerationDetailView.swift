import SwiftUI

/// One submission under review: its place in the archive, a link to preview the files, and the approve / reject
/// actions. Approving publishes the exam and credits the owner; rejecting records an optional reason.
struct ModerationDetailView: View {
    let record: ExamSubmissionRecord
    let viewModel: ModerationViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var isConfirmingReject = false
    @State private var rejectReason = ""
    @State private var approval: ApprovalResult?

    var body: some View {
        Form {
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
            Button {
                performApprove()
            } label: {
                HStack {
                    Label("Onayla ve Yayınla", systemImage: "checkmark.circle.fill")
                    Spacer()
                    if isWorking {
                        ProgressView()
                    }
                }
            }
            .disabled(isWorking)
            .accessibilityIdentifier("moderation.detail.approve")

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
            Text("Onaylarsan sınav arşive eklenir ve gönderene yenilik kademesine göre coin verilir.")
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

    private func performApprove() {
        errorMessage = nil
        isWorking = true
        Task {
            let outcome = await viewModel.approve(record)
            isWorking = false
            switch outcome {
            case let .approved(result):
                approval = result
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
                dismiss()
            }
        }
    }

    private var approvalBinding: Binding<Bool> {
        Binding(get: { approval != nil }, set: { if !$0 { approval = nil } })
    }

    private func approvalMessage(_ result: ApprovalResult) -> String {
        if result.coins > 0 {
            String(localized: "\(result.tier.label): gönderene \(result.coins) coin verildi.")
        } else {
            String(localized: "Gönderim onaylandı.")
        }
    }
}

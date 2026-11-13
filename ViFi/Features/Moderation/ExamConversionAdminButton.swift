import SwiftUI

/// "Yeni yapıya geçir" for one archive exam (K12a), a self-contained admin component: it hides itself unless the
/// signed-in user is an admin, asks for the AI provider, queues the conversion and shows the job's status.
///
/// Hooking (merge step, track 1C owns the exam screens): place `ExamConversionAdminButton(examId:)` in the exam
/// viewer's toolbar menu or a section of the legacy image/PDF screen, only for exams that are not yet structured.
/// `examId` is the Firestore `exams` document id (the last component of the exam's `ArchivePath`).
struct ExamConversionAdminButton: View {
    let examId: String

    @Environment(AppEnvironment.self) private var environment
    @State private var isAdmin = false
    @State private var isPickingProvider = false
    @State private var isWorking = false
    @State private var job: ExamConversion?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if isAdmin {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        isPickingProvider = true
                    } label: {
                        HStack {
                            Label("Yeni yapıya geçir", systemImage: "wand.and.stars")
                            if isWorking { ProgressView() }
                        }
                    }
                    .disabled(isWorking)
                    .accessibilityIdentifier("examAdmin.convert")

                    if let job {
                        Text(statusText(job))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("examAdmin.convert.status")
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("examAdmin.convert.error")
                    }
                }
                // Sits in the exam viewer's bottom inset: a bar only when there is something to show.
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
            }
        }
        .task { isAdmin = await environment.auth.isCurrentUserAdmin() }
        .aiProviderDialog("Hangi modelle dönüştürülsün?", isPresented: $isPickingProvider) { provider in
            Task { await start(with: provider) }
        }
    }

    private func start(with provider: AIProvider) async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            job = try await environment.conversionService.requestConversion(examId: examId, provider: provider)
        } catch {
            errorMessage = error.userMessage
        }
    }

    private func statusText(_ job: ExamConversion) -> String {
        let provider = job.provider.map { " (\($0.displayName))" } ?? ""
        switch job.status {
        case .queued: return String(localized: "Sıraya alındı\(provider)")
        case .processing: return String(localized: "İşleniyor\(provider)")
        case .ready: return String(localized: "Taslak hazır; Moderasyon › Hazır sınavlar'dan incele")
        case .failed: return String(localized: "İş başarısız oldu")
        case .published: return String(localized: "Yayınlandı")
        case .discarded: return String(localized: "İptal edildi")
        }
    }
}

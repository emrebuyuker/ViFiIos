import SwiftUI

/// The admin "Bildirim Gönder" form: kind, title and message, audience, action, image and timing, then a preview of the
/// exact reach and a confirmation before anything is sent. Reachable only from the account screen, and only by an
/// admin; its history is one toolbar button away.
struct NotificationComposerView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        NotificationComposerScreen(service: environment.notificationAdmin)
            .onAppear { environment.analytics.track(.screenView(name: "NotificationComposer")) }
    }
}

private struct NotificationComposerScreen: View {
    @State private var viewModel: NotificationComposerViewModel

    init(service: any NotificationAdminServicing) {
        _viewModel = State(initialValue: NotificationComposerViewModel(service: service))
    }

    var body: some View {
        Form {
            NotificationComposerKindSection(viewModel: viewModel)
            NotificationComposerContentSection(viewModel: viewModel)
            NotificationComposerAudienceSection(viewModel: viewModel)
            NotificationComposerActionSection(viewModel: viewModel)
            NotificationComposerImageSection(viewModel: viewModel)
            NotificationComposerTimingSection(viewModel: viewModel)
            NotificationComposerFeedbackSection(viewModel: viewModel)
            NotificationComposerSendSection(viewModel: viewModel)
        }
        .navigationTitle("Bildirim Gönder")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .animation(.smooth, value: viewModel.errorMessage)
        .animation(.smooth, value: viewModel.successMessage)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    NotificationHistoryView()
                } label: {
                    Label("Geçmiş", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("notificationComposer.history")
            }
        }
        .alert(
            confirmationTitle,
            isPresented: $viewModel.isConfirming,
            presenting: viewModel.confirmation
        ) { confirmation in
            Button(confirmation.draft.scheduledAt == nil ? "Gönder" : "Zamanla") {
                Task { await viewModel.confirmSend() }
            }
            .accessibilityIdentifier("notificationComposer.confirm")
            Button("Vazgeç", role: .cancel) {
                viewModel.cancelConfirmation()
            }
            .accessibilityIdentifier("notificationComposer.confirm.cancel")
        } message: { confirmation in
            Text(confirmationMessage(for: confirmation))
        }
        .task { await viewModel.loadFacetsIfNeeded() }
    }

    private var confirmationTitle: String {
        viewModel.draft.scheduledAt == nil
            ? String(localized: "Bildirim gönderilsin mi?")
            : String(localized: "Bildirim zamanlansın mı?")
    }

    /// The exact reach, so the admin sees who this really goes to before agreeing.
    private func confirmationMessage(for confirmation: NotificationSendConfirmation) -> String {
        let preview = confirmation.preview
        var message = String(
            localized: "\(preview.recipients) kişiye gönderilecek; \(preview.pushTargets) cihaza anlık bildirim (push) iletilecek."
        )
        if let date = confirmation.draft.scheduledAt {
            message += "\n" + String(localized: "Gönderim zamanı: \(date.formatted(date: .abbreviated, time: .shortened))")
        }
        return message
    }
}

#if DEBUG
#Preview("Bildirim Gönder") {
    NavigationStack {
        NotificationComposerView()
    }
    .environment(AppEnvironment.mock())
    .environment(Router())
}
#endif

import SwiftUI

/// Per-question admin actions on a published structured exam (K15): "Düzenle" (opens the editor, saves through
/// `updatePublishedQuestion`) and "Yeniden üret" (provider choice, then `regeneratePublishedQuestion`). A
/// self-contained component that hides itself for non-admins. Changes go live at once; the question id is permanent.
///
/// Hooking (merge step, track 1C owns the structured exam screen): place
/// `PublishedQuestionAdminActions(question:onChange:)` next to each question card (for example in its toolbar or a
/// `Menu`); `onChange` is called after a successful edit or regeneration request, so the screen can re-read the
/// questions (a regeneration finishes a few seconds later on the server).
struct PublishedQuestionAdminActions: View {
    let question: ExamQuestion
    var onChange: () -> Void = {}

    @Environment(AppEnvironment.self) private var environment
    @State private var isAdmin = false
    @State private var isEditing = false
    @State private var isPickingProvider = false
    @State private var isWorking = false
    @State private var message: String?

    var body: some View {
        Group {
            if isAdmin {
                Menu {
                    Button("Düzenle", systemImage: "pencil") { isEditing = true }
                        .accessibilityIdentifier("questionAdmin.edit")
                    Button("Yeniden üret", systemImage: "arrow.clockwise") { isPickingProvider = true }
                        .accessibilityIdentifier("questionAdmin.regenerate")
                } label: {
                    Label("Yönetici", systemImage: "wrench.and.screwdriver")
                }
                .disabled(isWorking)
                .accessibilityIdentifier("questionAdmin.menu")
                .padding(.bottom, 6)
                .sheet(isPresented: $isEditing) {
                    QuestionEditorView(question: question) { edited in
                        do {
                            try await environment.conversionService.updatePublishedQuestion(edited)
                            onChange()
                            return nil
                        } catch {
                            return error.userMessage
                        }
                    }
                }
                .aiProviderDialog("Soru hangi modelle yeniden üretilsin?", isPresented: $isPickingProvider) { provider in
                    Task { await regenerate(with: provider) }
                }
                .alert("Yönetici", isPresented: messageBinding) {
                    Button("Tamam") {}
                } message: {
                    Text(message ?? "")
                }
            } else {
                // A zero-size placeholder: an empty Group never appears, so its `.task` (the admin check) would
                // never run and the component would stay hidden even for admins.
                Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            }
        }
        .task { isAdmin = await environment.auth.isCurrentUserAdmin() }
    }

    private func regenerate(with provider: AIProvider) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await environment.conversionService.regeneratePublishedQuestion(questionId: question.id, provider: provider)
            message = String(localized: "Soru yeniden üretiliyor; birkaç saniye sonra yenile.")
            onChange()
        } catch {
            message = error.userMessage
        }
    }

    private var messageBinding: Binding<Bool> {
        Binding(get: { message != nil }, set: { if !$0 { message = nil } })
    }
}

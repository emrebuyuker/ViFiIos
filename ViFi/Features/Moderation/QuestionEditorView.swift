import SwiftUI

/// A sheet for editing one question's content (text, speech, choices, answer, solution). Used for a draft under
/// review and for a published question (K15); the caller supplies what "save" does and gets `true` back on success.
struct QuestionEditorView: View {
    let question: ExamQuestion
    let onSave: (ExamQuestion) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var draft: QuestionEditDraft
    @State private var isSaving = false
    @State private var errorMessage: String?

    /// - Parameter onSave: Saves the edited question; returns an error message, or `nil` on success.
    init(question: ExamQuestion, onSave: @escaping (ExamQuestion) async -> String?) {
        self.question = question
        self.onSave = onSave
        _draft = State(initialValue: QuestionEditDraft(question: question))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Soru metni (Markdown + LaTeX)") {
                    TextEditor(text: $draft.text)
                        .frame(minHeight: 120)
                        .accessibilityIdentifier("question.edit.text")
                }
                Section("Sesli okuma metni") {
                    TextEditor(text: $draft.speech)
                        .frame(minHeight: 70)
                        .accessibilityIdentifier("question.edit.speech")
                }
                choicesSection
                answerSection
                solutionSection
                if let message = errorMessage ?? draft.validationMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("question.edit.error")
                    }
                }
            }
            .navigationTitle("Soru \(question.label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { dismiss() }
                        .disabled(isSaving)
                        .accessibilityIdentifier("question.edit.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet") { save() }
                        .disabled(!draft.isValid || isSaving)
                        .accessibilityIdentifier("question.edit.save")
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
    }

    private var choicesSection: some View {
        Section("Şıklar") {
            ForEach($draft.choices) { $choice in
                HStack(alignment: .top) {
                    TextField("A", text: $choice.label)
                        .frame(width: 36)
                        .textInputAutocapitalization(.characters)
                    TextField("Şık metni", text: $choice.text, axis: .vertical)
                }
            }
            .onDelete { draft.choices.remove(atOffsets: $0) }
            if draft.choices.count < QuestionEditDraft.Limit.choices {
                Button("Şık ekle", systemImage: "plus") { draft.choices.append(.init()) }
            }
        }
    }

    private var answerSection: some View {
        Section("Cevap") {
            TextEditor(text: $draft.answerText)
                .frame(minHeight: 70)
                .accessibilityIdentifier("question.edit.answer")
            if !draft.choices.isEmpty {
                TextField("Doğru şık (örn. C)", text: $draft.answerChoice)
                    .textInputAutocapitalization(.characters)
            }
            TextField("Cevabın sesli okuma metni", text: $draft.answerSpeech, axis: .vertical)
        }
    }

    private var solutionSection: some View {
        Section("Çözüm adımları") {
            ForEach($draft.solution) { $step in
                TextField("Adım", text: $step.text, axis: .vertical)
            }
            .onDelete { draft.solution.remove(atOffsets: $0) }
            if draft.solution.count < QuestionEditDraft.Limit.solutionSteps {
                Button("Adım ekle", systemImage: "plus") { draft.solution.append(.init()) }
            }
        }
    }

    private func save() {
        guard draft.isValid, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        let edited = draft.applied(to: question)
        Task {
            let message = await onSave(edited)
            isSaving = false
            if let message {
                errorMessage = message
            } else {
                dismiss()
            }
        }
    }
}

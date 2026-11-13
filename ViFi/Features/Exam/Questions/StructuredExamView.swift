import SwiftUI

/// The screen of a structured exam (4.2.0): its questions as cards, each with "Cevabı Göster".
///
/// Opened by `ExamRouting` only for an exam with `format == "structured"` while the remote switch is on, and only
/// after the archive's lock rule let the user in. Question content is drawn inside the capture shield (see
/// `QuestionCardView`); the recording cover applies to the whole screen like on the file viewers.
struct StructuredExamView: View {
    let path: ArchivePath
    let kind: ExamKind

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        StructuredExamScreen(
            viewModel: StructuredExamViewModel(
                path: path,
                kind: kind,
                reader: environment.questionReader,
                recents: environment.recents,
                analytics: environment.analytics
            )
        )
    }
}

/// Owns the view model; `@State` keeps the first instance it is given for the screen's lifetime.
private struct StructuredExamScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var viewModel: StructuredExamViewModel
    @State private var loadAttempt = 0
    @State private var contactRequest: ContactRequest?

    init(viewModel: StructuredExamViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        content
            // One background for every state, behind the bars too, so nothing flashes white.
            .background(Color(.systemGroupedBackground))
            .navigationTitle(viewModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Faz 2: admin actions hook (track 1D attaches the "Yeni yapıya geçir" / edit toolbar items here).
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        contactRequest = ContactRequest(context: viewModel.supportContext)
                    } label: {
                        Label("Bize Ulaş", systemImage: "envelope")
                    }
                    .accessibilityIdentifier("exam.contact")
                }
            }
            .contactSupport(trigger: $contactRequest)
            .task(id: loadAttempt) {
                await viewModel.loadIfNeeded()
            }
            .onAppear { environment.analytics.track(.screenView(name: "StructuredExam")) }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            LoadingStateView()
        case let .failed(message):
            ErrorStateView(message: message) {
                loadAttempt += 1
            }
        case let .loaded(questions) where questions.isEmpty:
            EmptyStateView(title: "Bu sınavda soru yok", systemImage: "list.number")
        case let .loaded(questions):
            questionList(questions)
        }
    }

    private func questionList(_ questions: [ExamQuestion]) -> some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                ExamContextHeader(subtitle: viewModel.subtitle, questionCount: questions.count)

                ForEach(questions) { question in
                    QuestionCardView(
                        question: question,
                        isAnswerRevealed: viewModel.isAnswerRevealed(order: question.order),
                        onToggleAnswer: { viewModel.toggleAnswer(order: question.order) }
                    )
                }
            }
            .frame(maxWidth: Layout.readableWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, horizontalSizeClass == .regular ? 32 : 16)
            .padding(.vertical, 20)
        }
        .background(Color(.systemGroupedBackground))
        // Dynamic Type grows the cards up to a cap; beyond it the layout would stop fitting a phone.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityIdentifier("questions.list")
        .screenCaptureProtection()
    }

    private enum Layout {
        /// Cards wider than this are hard to read; iPad and landscape center them.
        static let readableWidth: CGFloat = 700
    }
}

// MARK: - Header

/// "BOZOK ÜNİVERSİTESİ › MÜHENDİSLİK MATEMATİĞİ · 12 soru", above the first card.
private struct ExamContextHeader: View {
    let subtitle: String
    let questionCount: Int

    var body: some View {
        HStack(spacing: 12) {
            IconBadge(systemName: "list.number", size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(subtitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text("\(questionCount) soru")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        StructuredExamView(path: .mockStructuredExam, kind: .images)
    }
    .environment(AppEnvironment.mock())
    .environment(Router())
}
#endif

import SwiftUI
import UIKit

/// One question as a card: "1. Soru", the question content and the "Cevabı Göster" button (4.2.0).
///
/// Reusable on purpose: the exam's question list uses it today and the future "Sınava gir" practice mode (ROADMAP
/// #4) shows the same card one question at a time. It owns no state: the caller decides whether the answer is
/// shown (`isAnswerRevealed`) and handles the button (`onToggleAnswer`).
///
/// The question, figures, choices and answer are drawn by `QuestionContentView` inside a `CaptureShieldedView`
/// (see `QuestionContentRepresentable`); only the header and the button are SwiftUI. Do not put the card under
/// `.drawingGroup()` or render it to an image: that bypasses the capture shield.
struct QuestionCardView: View {
    let question: ExamQuestion
    let isAnswerRevealed: Bool
    var onToggleAnswer: () -> Void

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(question.label). Soru")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)

            QuestionContentRepresentable(
                question: question,
                isAnswerRevealed: isAnswerRevealed,
                figureURLs: question.figures.map { environment.figureURL(for: $0) },
                loader: environment.fileLoader
            )

            revealButton
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: cardShape)
        .overlay { cardShape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5) }
        .clipShape(cardShape)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("questions.card.\(question.order)")
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
    }

    @ViewBuilder
    private var revealButton: some View {
        if isAnswerRevealed {
            Button(action: onToggleAnswer) {
                Label("Cevabı Gizle", systemImage: "eye.slash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("questions.reveal.\(question.order)")
        } else {
            // Black on the brand orange: white text would fall below 3:1 contrast.
            Button(action: onToggleAnswer) {
                Label("Cevabı Göster", systemImage: "eye")
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("questions.reveal.\(question.order)")
        }
    }
}

/// Hosts `QuestionContentView` in a `CaptureShieldedView` and sizes it to the card's width.
struct QuestionContentRepresentable: UIViewRepresentable {
    let question: ExamQuestion
    let isAnswerRevealed: Bool
    let figureURLs: [URL?]
    let loader: any RemoteFileLoading

    func makeUIView(context: Context) -> CaptureShieldedView<QuestionContentView> {
        CaptureShieldedView(content: QuestionContentView())
    }

    func updateUIView(_ uiView: CaptureShieldedView<QuestionContentView>, context: Context) {
        // Mutate in place; replacing the content view would leave the new one unflagged.
        uiView.content.configure(
            question: question, isAnswerRevealed: isAnswerRevealed, figureURLs: figureURLs, loader: loader
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: CaptureShieldedView<QuestionContentView>, context: Context) -> CGSize? {
        let width = proposal.width ?? 360
        return CGSize(width: width, height: uiView.content.height(fitting: width))
    }
}

#if DEBUG
#Preview("Soru kartı") {
    struct Host: View {
        @State private var revealed = false
        var body: some View {
            ScrollView {
                if let question = MockExamQuestionReader.sampleQuestions(examId: "preview").dropFirst().first {
                    QuestionCardView(question: question, isAnswerRevealed: revealed) { revealed.toggle() }
                        .padding()
                }
            }
            .background(Color(.systemGroupedBackground))
        }
    }
    return Host().environment(AppEnvironment.mock())
}
#endif

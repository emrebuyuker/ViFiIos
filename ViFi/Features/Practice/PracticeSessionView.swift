import SwiftUI

/// The practice session: one question card at a time with "Cevabı Göster", "Sıradaki soru" and "Bitir".
///
/// The question is drawn by `QuestionCardView` inside the capture shield; the recording cover applies to the whole
/// screen like on the structured exam screen. Free users see how many questions are left today; when the limit is
/// used up the paywall is offered.
struct PracticeSessionView: View {
    let viewModel: PracticeSessionViewModel
    let onFinish: () -> Void

    var body: some View {
        PracticeSessionScreen(viewModel: viewModel, onFinish: onFinish)
    }
}

/// Owns the view model; `@State` keeps the first instance it is given for the screen's lifetime.
private struct PracticeSessionScreen: View {
    let onFinish: () -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var viewModel: PracticeSessionViewModel
    @State private var isShowingPaywall = false

    init(viewModel: PracticeSessionViewModel, onFinish: @escaping () -> Void) {
        _viewModel = State(initialValue: viewModel)
        self.onFinish = onFinish
    }

    var body: some View {
        content
            .background(Color(.systemGroupedBackground))
            .navigationTitle(viewModel.selection.examType.practiceTitle)
            .navigationBarTitleDisplayMode(.inline)
            .task { await viewModel.start() }
            .onDisappear { viewModel.stop() }
            .onAppear { environment.analytics.track(.screenView(name: "PracticeSession")) }
            .sheet(isPresented: $isShowingPaywall) { PaywallView() }
            .screenCaptureProtection()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .loading:
            LoadingStateView()
        case let .failed(message):
            ErrorStateView(message: message) {
                Task { await viewModel.next() }
            }
        case .question:
            questionScreen
        case .exhausted:
            exhaustedScreen
        case .limitReached:
            limitScreen
        }
    }

    private var questionScreen: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        header
                            .id(Anchor.top)
                        if let current = viewModel.current {
                            QuestionCardView(
                                question: current.question,
                                isAnswerRevealed: viewModel.isAnswerRevealed,
                                title: String(localized: "Soru \(viewModel.questionNumber)"),
                                onToggleAnswer: { viewModel.toggleAnswer() }
                            )
                        }
                    }
                    .frame(maxWidth: Layout.readableWidth)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, horizontalSizeClass == .regular ? 32 : 16)
                    .padding(.vertical, 16)
                }
                .onChange(of: viewModel.current?.id) {
                    proxy.scrollTo(Anchor.top, anchor: .top)
                }
            }
            actionBar
        }
        // Dynamic Type grows the cards up to a cap; beyond it the layout would stop fitting a phone.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("practice.session")
    }

    /// "BOZOK ÜNİVERSİTESİ · 2019 FİNAL" and, for free users, "Bugün kalan: N soru".
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let source = viewModel.current?.sourceLine {
                Text(source)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("practice.source")
            }
            if let remaining = viewModel.remainingToday {
                Text("Bugün kalan: \(remaining) soru")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("practice.remaining")
            }
        }
    }

    private var actionBar: some View {
        VStack(spacing: 8) {
            Button {
                Task { await viewModel.next() }
            } label: {
                // Black on the brand orange: white text would fall below 3:1 contrast.
                Label("Sıradaki soru", systemImage: "arrow.right")
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("practice.next")

            Button(action: onFinish) {
                Text("Bitir")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("practice.finish")
        }
        .frame(maxWidth: Layout.readableWidth)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    // MARK: - End states

    private var exhaustedScreen: some View {
        endState(
            symbol: "checkmark.circle",
            title: "Bu kapsamdaki tüm soruları gördün",
            message: "İstersen aynı sorulara baştan başlayabilir ya da çıkabilirsin.",
            identifier: "practice.exhausted"
        ) {
            Button {
                Task { await viewModel.restart() }
            } label: {
                Label("Baştan başla", systemImage: "arrow.counterclockwise")
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("practice.restart")
        }
    }

    private var limitScreen: some View {
        endState(
            symbol: "lock.fill",
            title: "Bugünlük ücretsiz soru hakkın bitti",
            message: "Ücretsiz soru hakkı her gün yenilenir. Premium ile istediğin kadar soru çözebilirsin.",
            identifier: "practice.limit"
        ) {
            Button {
                viewModel.paywallOpened()
                isShowingPaywall = true
            } label: {
                Label("Premium'a Göz At", systemImage: "star.fill")
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("practice.paywall")
        }
    }

    /// A centered message with a primary action and "Bitir".
    private func endState(
        symbol: String,
        title: LocalizedStringKey,
        message: LocalizedStringKey,
        identifier: String,
        @ViewBuilder primary: () -> some View
    ) -> some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            Image(systemName: symbol)
                .font(.system(size: 44))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .accessibilityElement(children: .combine)
            VStack(spacing: 8) {
                primary()
                Button(action: onFinish) {
                    Text("Bitir")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("practice.finish")
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: Layout.readableWidth)
        .padding(24)
        .frame(maxWidth: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    private enum Anchor: Hashable { case top }

    private enum Layout {
        /// Cards wider than this are hard to read; iPad and landscape center them.
        static let readableWidth: CGFloat = 700
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        PracticeSessionView(
            viewModel: PracticeSessionViewModel(
                selection: PracticeSelection(
                    subjectId: "topoloji-1", examType: .final, scope: .turkey,
                    courseId: "TOPOLOJİ 1", universityId: nil, poolCount: 3
                ),
                service: MockPracticeService(),
                analytics: NoOpAnalyticsTracker()
            ),
            onFinish: {}
        )
    }
    .environment(AppEnvironment.mock())
}
#endif

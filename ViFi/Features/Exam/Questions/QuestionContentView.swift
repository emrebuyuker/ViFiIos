import UIKit

/// The UIKit content of one question card: question text, figures and choices, plus the answer and the worked
/// solution once revealed (4.2.0).
///
/// Every pixel of exam content is drawn by this view, so it is only ever created as the `content` of a
/// `CaptureShieldedView` (see `QuestionContentRepresentable`). It is opaque (`secondarySystemGroupedBackground`),
/// as the shield requires, and is configured **in place**: `configure` rebuilds its subviews but the view itself is
/// never replaced, or the new one would be unflagged.
///
/// Accessibility: the question and the answer are two accessibility elements reading `speech` and
/// `answer.speech ?? answer.text` instead of LaTeX.
final class QuestionContentView: UIView {
    private let root = UIStackView()
    private let questionStack = UIStackView()
    private let answerStack = UIStackView()

    /// What the caller asked to show.
    private struct Input: Equatable {
        let question: ExamQuestion
        let isAnswerRevealed: Bool
        let figureURLs: [URL?]
    }

    /// What the subviews were last built from, so an unchanged update does not rebuild them.
    private struct Applied: Equatable {
        let input: Input
        let sizeCategory: UIContentSizeCategory
        let userInterfaceStyle: UIUserInterfaceStyle
    }

    private var applied: Applied?
    private var loader: (any RemoteFileLoading)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemGroupedBackground
        isOpaque = true
        isAccessibilityElement = false

        root.axis = .vertical
        root.spacing = 16
        root.isLayoutMarginsRelativeArrangement = true
        root.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 16, bottom: 16, trailing: 16)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: topAnchor),
            root.bottomAnchor.constraint(equalTo: bottomAnchor),
            root.leadingAnchor.constraint(equalTo: leadingAnchor),
            root.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        for stack in [questionStack, answerStack] {
            stack.axis = .vertical
            stack.spacing = 12
            stack.isAccessibilityElement = true
            root.addArrangedSubview(stack)
        }
        answerStack.isHidden = true

        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self]) { (view: QuestionContentView, _) in
            view.rebuild()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {}

    private var pending: Input?

    /// Shows `question`, with its answer and solution when `isAnswerRevealed`. `figureURLs` parallels
    /// `question.figures` (a `nil` entry is a figure that cannot be addressed and shows as unavailable).
    func configure(
        question: ExamQuestion,
        isAnswerRevealed: Bool,
        figureURLs: [URL?],
        loader: any RemoteFileLoading
    ) {
        self.loader = loader
        pending = Input(question: question, isAnswerRevealed: isAnswerRevealed, figureURLs: figureURLs)
        rebuild()
    }

    // MARK: - Building

    private func rebuild() {
        guard let pending, let loader else { return }
        let current = Applied(
            input: pending,
            sizeCategory: traitCollection.preferredContentSizeCategory,
            userInterfaceStyle: traitCollection.userInterfaceStyle
        )
        guard current != applied else { return }
        applied = current

        let style = FormulaText.Style.body(traits: traitCollection)
        let views = questionViews(
            for: pending.question, style: style, loader: loader, figureURLs: pending.figureURLs, revealed: pending.isAnswerRevealed
        )
        replaceContents(of: questionStack, with: views)
        accessibilityIdentifier = "questions.content.\(pending.question.order)"
        questionStack.accessibilityIdentifier = "questions.question.\(pending.question.order)"
        questionStack.accessibilityLabel = Self.questionSpeech(pending.question)

        answerStack.isHidden = !pending.isAnswerRevealed
        if pending.isAnswerRevealed {
            replaceContents(of: answerStack, with: answerViews(for: pending.question, style: style))
            answerStack.accessibilityIdentifier = "questions.answer.\(pending.question.order)"
            answerStack.accessibilityLabel = Self.answerSpeech(pending.question)
            accessibilityElements = [questionStack, answerStack]
        } else {
            replaceContents(of: answerStack, with: [])
            accessibilityElements = [questionStack]
        }
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    private func replaceContents(of stack: UIStackView, with views: [UIView]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for view in views { stack.addArrangedSubview(view) }
    }

    private func questionViews(
        for question: ExamQuestion, style: FormulaText.Style, loader: any RemoteFileLoading,
        figureURLs: [URL?], revealed: Bool
    ) -> [UIView] {
        var views = FormulaText.views(for: question.text, style: style)
        for (index, figure) in question.figures.enumerated() {
            let url = index < figureURLs.count ? figureURLs[index] : nil
            views.append(QuestionFigureView(figure: figure, url: url, loader: loader))
        }
        for choice in question.choices {
            let isCorrect = revealed && choice.label == question.answer.choice
            let marker = isCorrect ? "\(choice.label) ✓" : choice.label
            let markerFont = UIFont.systemFont(ofSize: style.font.pointSize, weight: .semibold)
            views.append(row(marker: marker, text: choice.text, markerStyle: style.with(font: markerFont), style: style))
        }
        return views
    }

    private func answerViews(for question: ExamQuestion, style: FormulaText.Style) -> [UIView] {
        var views: [UIView] = [separator()]
        views.append(heading(String(localized: "Cevap"), style: style))
        if let choice = question.answer.choice, !choice.isEmpty {
            let text = String(localized: "Doğru seçenek: \(choice)")
            views.append(FormulaText.label(for: FormulaText.markdown(text, style: style.with(font: boldFont(style.font)))))
        }
        views.append(contentsOf: FormulaText.views(for: question.answer.text, style: style))
        if !question.solution.isEmpty {
            views.append(heading(String(localized: "Çözüm"), style: style))
            for (index, step) in question.solution.enumerated() {
                views.append(row(marker: "\(index + 1).", text: step, markerStyle: style, style: style))
            }
        }
        let noteFont = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: .systemFont(ofSize: 13), maximumPointSize: 24, compatibleWith: traitCollection)
        let noteStyle = FormulaText.Style(font: noteFont, color: UIColor.secondaryLabel.resolvedColor(with: traitCollection))
        views.append(FormulaText.label(for: FormulaText.markdown(Self.aiNote, style: noteStyle)))
        return views
    }

    /// K10: the short, plain note under every revealed answer.
    static var aiNote: String { String(localized: "Bu çözüm yapay zekâ ile hazırlanmış ve incelenmiştir.") }

    /// A marker ("A", "1.") beside the blocks of `text`.
    private func row(marker: String, text: String, markerStyle: FormulaText.Style, style: FormulaText.Style) -> UIView {
        let markerLabel = FormulaText.label(for: NSAttributedString(
            string: marker, attributes: [.font: markerStyle.font, .foregroundColor: markerStyle.color]
        ))
        markerLabel.numberOfLines = 1
        markerLabel.setContentHuggingPriority(.required, for: .horizontal)
        markerLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        let blocks = UIStackView(arrangedSubviews: FormulaText.views(for: text, style: style))
        blocks.axis = .vertical
        blocks.spacing = 8
        let row = UIStackView(arrangedSubviews: [markerLabel, blocks])
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 10
        // The marker column keeps a minimum width so choices line up.
        markerLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: style.font.pointSize * 1.6).isActive = true
        return row
    }

    private func heading(_ title: String, style: FormulaText.Style) -> UILabel {
        let label = FormulaText.label(for: NSAttributedString(
            string: title, attributes: [.font: boldFont(style.font), .foregroundColor: style.color]
        ))
        label.numberOfLines = 1
        return label
    }

    private func boldFont(_ font: UIFont) -> UIFont {
        UIFont.systemFont(ofSize: font.pointSize, weight: .semibold)
    }

    private func separator() -> UIView {
        let line = UIView()
        line.backgroundColor = .separator
        line.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1)).isActive = true
        return line
    }

    // MARK: - VoiceOver

    /// The question for VoiceOver: the stored `speech`, then the choices; a figure is announced.
    static func questionSpeech(_ question: ExamQuestion) -> String {
        var parts = [question.speech.isEmpty ? MathTextTokenizer.plainText(question.text) : question.speech]
        if !question.figures.isEmpty { parts.append(String(localized: "Şekil var.")) }
        for choice in question.choices {
            parts.append("\(choice.label): \(MathTextTokenizer.plainText(choice.text))")
        }
        return parts.joined(separator: " ")
    }

    /// The answer for VoiceOver: `answer.speech ?? answer.text`, then the solution steps and the AI note.
    static func answerSpeech(_ question: ExamQuestion) -> String {
        let answer = question.answer.speech ?? MathTextTokenizer.plainText(question.answer.text)
        var parts = [String(localized: "Cevap:") + " " + answer]
        if let choice = question.answer.choice, !choice.isEmpty {
            parts.insert(String(localized: "Doğru seçenek: \(choice)."), at: 0)
        }
        if !question.solution.isEmpty {
            parts.append(String(localized: "Çözüm:") + " " + question.solution.map(MathTextTokenizer.plainText).joined(separator: " "))
        }
        parts.append(aiNote)
        return parts.joined(separator: " ")
    }

    // MARK: - Sizing

    /// The height this content needs at `width`.
    func height(fitting width: CGFloat) -> CGFloat {
        let target = CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        return ceil(systemLayoutSizeFitting(
            target, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel
        ).height)
    }
}

/// A question figure, downloaded only once it reaches the screen (`didMoveToWindow`) through `RemoteFileLoader`.
/// The placeholder keeps the figure's aspect ratio (or 3:2 when unknown), so the card does not jump on load.
final class QuestionFigureView: UIView {
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let failureLabel = UILabel()
    private let url: URL?
    private let loader: any RemoteFileLoading
    private var task: Task<Void, Never>?

    init(figure: QuestionFigure, url: URL?, loader: any RemoteFileLoading) {
        self.url = url
        self.loader = loader
        super.init(frame: .zero)
        // Opaque white like the exam page it was cropped from.
        backgroundColor = .white
        isOpaque = true
        layer.cornerRadius = 8
        clipsToBounds = true
        isAccessibilityElement = false

        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        spinner.color = .darkGray
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        failureLabel.text = String(localized: "Şekil yüklenemedi")
        failureLabel.font = .preferredFont(forTextStyle: .footnote)
        failureLabel.textColor = .darkGray
        failureLabel.textAlignment = .center
        failureLabel.numberOfLines = 0
        failureLabel.isHidden = true
        failureLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(failureLabel)

        let ratio: CGFloat
        if let width = figure.width, let height = figure.height, width > 0, height > 0 {
            ratio = CGFloat(height) / CGFloat(width)
        } else {
            ratio = 2.0 / 3.0
        }
        let height = heightAnchor.constraint(equalTo: widthAnchor, multiplier: min(max(ratio, 0.1), 2))
        height.priority = .required
        NSLayoutConstraint.activate([
            height,
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            failureLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            failureLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            failureLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    deinit {
        task?.cancel()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, imageView.image == nil, task == nil else { return }
        load()
    }

    private func load() {
        guard let url else {
            showFailure()
            return
        }
        failureLabel.isHidden = true
        spinner.startAnimating()
        let loader = loader
        task = Task { [weak self] in
            let image = try? await loader.image(from: url, maxPixelSize: 1600)
            guard !Task.isCancelled, let self else { return }
            self.task = nil
            self.spinner.stopAnimating()
            if let image {
                self.imageView.image = image
            } else {
                self.showFailure()
            }
        }
    }

    private func showFailure() {
        spinner.stopAnimating()
        failureLabel.isHidden = false
    }
}

import SwiftUI

/// "Son Görüntülenenler": a horizontally scrolling shelf of recently opened exams.
///
/// Pure UI: the owner decides what opening, removing and clearing do.
struct RecentExamsSection: View {
    let exams: [RecentExam]
    let onOpen: (RecentExam) -> Void
    let onRemove: (RecentExam) -> Void
    let onClear: () -> Void

    @State private var isConfirmingClear = false

    var body: some View {
        Section {
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(exams) { exam in
                        RecentExamCard(exam: exam) { onOpen(exam) }
                            .contextMenu {
                                Button("Listeden Kaldır", systemImage: "minus.circle", role: .destructive) {
                                    onRemove(exam)
                                }
                            }
                            .accessibilityAction(named: "Listeden Kaldır") { onRemove(exam) }
                    }
                }
                .scrollTargetLayout()
                // Equal-height cards: measure the tallest, then let every card fill that height.
                .fixedSize(horizontal: false, vertical: true)
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .accessibilityIdentifier("home.recents")
            // Cards line up with the edges of the grouped rows below them.
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
        } header: {
            header
        }
        .headerProminence(.increased)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Son Görüntülenenler")
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 8)

            Button("Temizle") {
                isConfirmingClear = true
            }
            .font(.subheadline.weight(.medium))
            .buttonStyle(.borderless)
            .accessibilityIdentifier("home.recents.clear")
            .confirmationDialog(
                "Son görüntülenenler temizlensin mi?",
                isPresented: $isConfirmingClear,
                titleVisibility: .visible
            ) {
                Button("Tümünü Temizle", role: .destructive, action: onClear)
                    .accessibilityIdentifier("home.recents.clear.confirm")
            } message: {
                Text("Sınavlar arşivde kalmaya devam eder; yalnızca bu liste boşaltılır.")
            }
        }
        .textCase(nil)
    }
}

/// A card of the recents shelf: format, exam name, where it lives and when it was opened.
private struct RecentExamCard: View {
    let exam: RecentExam
    let action: () -> Void

    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 220
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Two lines normally; the whole text at accessibility sizes.
    private var lineLimit: Int? {
        dynamicTypeSize.isAccessibilitySize ? nil : 2
    }

    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

    var body: some View {
        Button {
            action()
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    IconBadge(systemName: exam.kind.symbolName, size: 36)
                    Spacer(minLength: 8)
                    ExamKindBadge(kind: exam.kind)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(exam.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(lineLimit)
                    Text(exam.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(lineLimit)
                }
                .multilineTextAlignment(.leading)

                Spacer(minLength: 0)

                TimelineView(.everyMinute) { _ in
                    Label(openedText, systemImage: "clock")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(width: min(width, 320), alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color(.secondarySystemGroupedBackground), in: shape)
            .contentShape(.contextMenuPreview, shape)
            .contentShape(.hoverEffect, shape)
        }
        .buttonStyle(PressableCardButtonStyle())
        .hoverEffect(.lift)
        .accessibilityLabel(accessibilityDescription)
        .accessibilityHint("Sınavı açar")
        .accessibilityIdentifier("recent.\(exam.title)")
    }

    private var openedText: String {
        exam.openedAt.formatted(.relative(presentation: .named))
    }

    /// The card read as a sentence, without the "›" separator of the visual subtitle.
    private var accessibilityDescription: String {
        let components = exam.path.components
        let location = [components.first, components.dropLast().last].compactMap(\.self)
        return ([exam.title, exam.kind.badge] + location + [openedText]).joined(separator: ", ")
    }
}

/// Shrinks the card slightly while pressed.
private struct PressableCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}

#if DEBUG
#Preview("Son Görüntülenenler") {
    let lesson = ArchivePath(components: [
        "BOZOK ÜNİVERSİTESİ", "MÜHENDİSLİK MİMARLIK FAKÜLTESİ", "BİLGİSAYAR MÜHENDİSLİĞİ", "MÜHENDİSLİK MATEMATİĞİ",
    ])
    let exams = [
        RecentExam(path: lesson.appending("2019 FİNAL"), kind: .images, openedAt: .now.addingTimeInterval(-90)),
        RecentExam(path: lesson.appending("2018 VİZE"), kind: .pdf, openedAt: .now.addingTimeInterval(-86_400)),
        RecentExam(
            path: ArchivePath(components: [
                "KÜTAHYA DUMLUPINAR ÜNİVERSİTESİ", "FEN EDEBİYAT FAKÜLTESİ", "FİZİK BÖLÜMÜ", "KUANTUM FİZİĞİ", "2020 BÜTÜNLEME",
            ]),
            kind: .pdf,
            openedAt: .now.addingTimeInterval(-7 * 86_400)
        ),
    ]

    NavigationStack {
        List {
            RecentExamsSection(exams: exams, onOpen: { _ in }, onRemove: { _ in }, onClear: {})
        }
        .navigationTitle("ViFi")
    }
    .environment(AppEnvironment.mock())
    .environment(Router())
}
#endif

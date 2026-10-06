import SwiftUI

/// A list row for an archive entry: icon badge, name, a short summary and, for exams, a format badge.
///
/// Exams without files keep their place in the list but are drawn dimmed with "Dosya bulunamadı".
/// Use `ArchiveNavigationRow` to get the row wired for navigation.
struct ArchiveRow: View {
    let item: ArchiveItem

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .headline) private var iconSize: CGFloat = 40

    var body: some View {
        HStack(spacing: 14) {
            IconBadge(
                systemName: symbolName,
                tint: isUnavailable ? .secondary : .accentColor,
                size: min(iconSize, 64)
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.headline)
                    .foregroundStyle(isUnavailable ? HierarchicalShapeStyle.secondary : .primary)
                    // Accessibility sizes leave room for only a few characters per line; show the whole name.
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .multilineTextAlignment(.leading)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if stacksBadge, let exam = item.exam {
                    ExamKindBadge(kind: exam.kind)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !stacksBadge, let exam = item.exam {
                ExamKindBadge(kind: exam.kind)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    /// An exam node that exists but has no files to open.
    private var isUnavailable: Bool {
        item.level == .exam && item.exam == nil
    }

    /// At accessibility text sizes the badge moves under the subtitle so the name keeps its width.
    private var stacksBadge: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var symbolName: String {
        item.exam?.kind.symbolName ?? item.level.symbolName
    }

    private var subtitle: String {
        if let exam = item.exam {
            exam.kind.contentText(fileCount: exam.fileCount)
        } else if item.level == .exam {
            String(localized: "Dosya bulunamadı")
        } else {
            item.level.childCountText(item.childCount ?? 0)
        }
    }
}

/// `ArchiveRow` wired for navigation: lists push their children, exams open their viewer.
///
/// Carries the `row.<name>` accessibility identifier used by UI tests.
struct ArchiveNavigationRow: View {
    let item: ArchiveItem

    var body: some View {
        Group {
            if let route = item.route {
                NavigationLink(value: route) {
                    ArchiveRow(item: item)
                }
            } else {
                // A disabled button (rather than plain content) tells VoiceOver and UI tests
                // that the entry exists but can't be opened.
                Button {
                    // Nothing to open: the exam has no files.
                } label: {
                    ArchiveRow(item: item)
                }
                .disabled(true)
            }
        }
        .accessibilityIdentifier("row.\(item.name)")
    }
}

extension ArchiveItem {
    /// Where tapping the entry leads; `nil` for an exam without files.
    var route: Route? {
        guard level == .exam else { return .browse(path) }
        return exam.map { .exam(path, $0.kind) }
    }
}

/// Small capsule naming an exam's format ("Görsel", "PDF").
struct ExamKindBadge: View {
    let kind: ExamKind

    var body: some View {
        Text(kind.badge)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color(.tertiarySystemFill), in: .capsule)
            .fixedSize()
    }
}

/// Section header with the list title and, once known, the number of entries.
struct ArchiveSectionHeader: View {
    let title: LocalizedStringResource
    var count: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)

            Spacer(minLength: 8)

            if let count {
                Text(count, format: .number)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(count)))
                    .animation(.snappy, value: count)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

#if DEBUG
private extension ArchiveItem {
    static let previewSamples: [ArchiveItem] = {
        let lesson = ArchivePath(components: [
            "BOZOK ÜNİVERSİTESİ", "MÜHENDİSLİK MİMARLIK FAKÜLTESİ", "BİLGİSAYAR MÜHENDİSLİĞİ", "MÜHENDİSLİK MATEMATİĞİ",
        ])
        return [
            ArchiveItem(path: lesson.prefix(1), level: .university, childCount: 1, exam: nil),
            ArchiveItem(
                path: ArchivePath(components: ["KÜTAHYA DUMLUPINAR ÜNİVERSİTESİ"]),
                level: .university,
                childCount: 12,
                exam: nil
            ),
            ArchiveItem(path: lesson, level: .lesson, childCount: 2, exam: nil),
            ArchiveItem(
                path: lesson.appending("2019 FİNAL"),
                level: .exam,
                childCount: nil,
                exam: ExamSummary(kind: .images, fileCount: 3)
            ),
            ArchiveItem(
                path: lesson.appending("2018 VİZE"),
                level: .exam,
                childCount: nil,
                exam: ExamSummary(kind: .pdf, fileCount: 1)
            ),
            ArchiveItem(path: lesson.appending("2017 BÜTÜNLEME"), level: .exam, childCount: nil, exam: nil),
        ]
    }()
}

#Preview("Satırlar") {
    NavigationStack {
        List(ArchiveItem.previewSamples) { item in
            ArchiveNavigationRow(item: item)
        }
        .navigationTitle("Satırlar")
    }
    .environment(AppEnvironment.mock())
    .environment(Router())
}
#endif

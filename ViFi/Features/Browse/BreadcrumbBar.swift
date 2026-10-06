import SwiftUI

/// Horizontally scrolling trail of the current archive location: "Üniversiteler › … › current".
///
/// Chip `i` stands for `path.prefix(i)`, so chip 0 is the university list. The last chip is the
/// current screen: highlighted and not tappable. The bar keeps the current chip scrolled into view.
struct BreadcrumbBar: View {
    let path: ArchivePath
    /// Called with the ancestor path of the tapped chip.
    let onSelect: (ArchivePath) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(0...path.depth, id: \.self) { index in
                    if index > 0 {
                        Image(systemName: "chevron.forward")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                    chip(at: index)
                }
            }
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        // Start scrolled to the end so the current chip is visible. A `ScrollViewReader.scrollTo`
        // on appear runs before the first layout and leaves the trail at its leading edge.
        .defaultScrollAnchor(.trailing)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Konum")
    }

    @ViewBuilder
    private func chip(at index: Int) -> some View {
        let isCurrent = index == path.depth
        let label = BreadcrumbChip(
            title: title(at: index),
            systemImage: index == 0 ? ArchiveLevel.university.symbolName : nil,
            isCurrent: isCurrent
        )

        if isCurrent {
            label
                .accessibilityAddTraits(.isSelected)
                .accessibilityIdentifier("breadcrumb.\(index)")
        } else {
            Button {
                onSelect(path.prefix(index))
            } label: {
                label
            }
            .buttonStyle(.plain)
            .hoverEffect()
            .accessibilityHint("Bu seviyeye döner")
            .accessibilityIdentifier("breadcrumb.\(index)")
        }
    }

    private func title(at index: Int) -> Text {
        index == 0 ? Text("Üniversiteler") : Text(verbatim: path.components[index - 1])
    }
}

/// One capsule of the breadcrumb trail.
private struct BreadcrumbChip: View {
    let title: Text
    let systemImage: String?
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .imageScale(.small)
                    .foregroundStyle(Color.accentColor)
            }
            title
                .lineLimit(1)
        }
        .font(.subheadline.weight(isCurrent ? .semibold : .medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(background, in: .capsule)
        .overlay {
            if isCurrent {
                Capsule()
                    .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
            }
        }
        .contentShape(.capsule)
        .accessibilityElement(children: .combine)
    }

    private var background: Color {
        isCurrent ? Color.accentColor.opacity(0.16) : Color(.secondarySystemGroupedBackground)
    }
}

#if DEBUG
#Preview("Breadcrumb") {
    NavigationStack {
        List {
            Section {
                BreadcrumbBar(
                    path: ArchivePath(components: [
                        "KÜTAHYA DUMLUPINAR ÜNİVERSİTESİ", "FEN EDEBİYAT FAKÜLTESİ", "FİZİK BÖLÜMÜ", "KUANTUM FİZİĞİ",
                    ])
                ) { _ in }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }
            Section {
                BreadcrumbBar(path: ArchivePath(components: ["BOZOK ÜNİVERSİTESİ"])) { _ in }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Breadcrumb")
    }
    .environment(AppEnvironment.mock())
    .environment(Router())
}
#endif

import SwiftUI

/// A chosen catalog value: the display `name`, its canonical `id` (for notification segments), and whether it
/// was free-typed rather than picked from the list.
nonisolated struct CatalogSelection: Equatable, Sendable {
    var name: String
    var id: String
    var isCustom: Bool

    static let empty = CatalogSelection(name: "", id: "", isCustom: false)

    var isEmpty: Bool { name.isEmpty }

    /// A value picked from the bundled list (canonical id).
    static func catalog(_ item: CatalogItem) -> CatalogSelection {
        CatalogSelection(name: item.name, id: item.id, isCustom: false)
    }

    /// A value the user typed that is not on the list (best-effort slug id, flagged custom).
    static func custom(_ text: String) -> CatalogSelection {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return CatalogSelection(name: trimmed, id: Slug.make(trimmed), isCustom: true)
    }

    /// Rebuilds a selection from stored profile fields (the edit screen's prefill).
    static func stored(name: String, id: String, isCustom: Bool) -> CatalogSelection {
        CatalogSelection(name: name, id: id, isCustom: isCustom)
    }
}

/// A searchable list the user picks a value from, with a free-text fallback: whatever is typed in the search
/// field can be used as-is, so a university / faculty / department that is not on the bundled list is still
/// accepted (as a custom, slugged value).
///
/// Pushed onto the surrounding navigation stack; choosing a value sets the binding and pops back.
struct CatalogPickerView: View {
    let title: LocalizedStringKey
    /// All options, already sorted; filtered live by the search text.
    let options: [CatalogItem]
    /// Accessibility identifier prefix, e.g. `profile.university` → `.option` / `.custom` rows.
    let accessibilityPrefix: String
    @Binding var selection: CatalogSelection

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matches: [CatalogItem] {
        UniversityCatalog.filtered(options, matching: query)
    }

    /// Whether to offer the typed text itself (it is not already an exact option by name).
    private var showsCustomOption: Bool {
        !trimmedQuery.isEmpty && !options.contains { $0.name.caseInsensitiveCompare(trimmedQuery) == .orderedSame }
    }

    var body: some View {
        List {
            if showsCustomOption {
                Section {
                    Button {
                        choose(.custom(trimmedQuery))
                    } label: {
                        Label {
                            Text("\"\(trimmedQuery)\" kullan")
                        } icon: {
                            Image(systemName: "plus.circle")
                        }
                    }
                    .accessibilityIdentifier("\(accessibilityPrefix).custom")
                } footer: {
                    Text("Aradığın listede yoksa, yazdığın metni olduğu gibi kullanabilirsin.")
                }
            }

            Section {
                ForEach(matches) { item in
                    Button {
                        choose(.catalog(item))
                    } label: {
                        HStack {
                            Text(item.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if item.id == selection.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .accessibilityIdentifier("\(accessibilityPrefix).option")
                    .accessibilityAddTraits(item.id == selection.id ? [.isSelected] : [])
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Ara")
        .autocorrectionDisabled()
    }

    private func choose(_ newSelection: CatalogSelection) {
        selection = newSelection
        dismiss()
    }
}

#if DEBUG
#Preview("Seçici") {
    @Previewable @State var selection = CatalogSelection.catalog(CatalogItem(id: "bogazici-universitesi", name: "Boğaziçi Üniversitesi"))
    return NavigationStack {
        CatalogPickerView(
            title: "Üniversite",
            options: [
                CatalogItem(id: "bogazici-universitesi", name: "Boğaziçi Üniversitesi"),
                CatalogItem(id: "ege-universitesi", name: "Ege Üniversitesi"),
            ],
            accessibilityPrefix: "profile.university",
            selection: $selection
        )
    }
}
#endif

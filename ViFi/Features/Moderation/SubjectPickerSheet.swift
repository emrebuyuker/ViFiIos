import SwiftUI

/// What the admin picked in `SubjectPickerSheet`.
enum SubjectPick {
    case existing(AdminSubject)
    case new(name: String)
}

/// Searchable list of subjects to move a course to or merge a subject into. With `allowsNew`, a typed name that
/// matches no subject offers "yeni ders oluştur".
struct SubjectPickerSheet: View {
    let title: String
    let subjects: [AdminSubject]
    let allowsNew: Bool
    let onPick: (SubjectPick) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if allowsNew, let name = newName {
                    Section {
                        Button {
                            onPick(.new(name: name))
                        } label: {
                            Label("“\(name)” adında yeni ders oluştur", systemImage: "plus.circle")
                        }
                        .accessibilityIdentifier("subjects.picker.new")
                    }
                }
                Section {
                    ForEach(matches) { subject in
                        Button {
                            onPick(.existing(subject))
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(subject.name)
                                    .foregroundStyle(.primary)
                                Text("\(subject.courseCount) ders · \(subject.questionCount) soru")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("subjects.picker.row.\(subject.id)")
                    }
                }
            }
            .accessibilityIdentifier("subjects.picker")
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Ders ara")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Vazgeç") { dismiss() }
                        .accessibilityIdentifier("subjects.picker.cancel")
                }
            }
        }
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var matches: [AdminSubject] {
        guard !trimmedQuery.isEmpty else { return subjects }
        let folded = Self.fold(trimmedQuery)
        return subjects.filter { Self.fold($0.name).contains(folded) }
    }

    /// The typed name when no subject already has it.
    private var newName: String? {
        guard !trimmedQuery.isEmpty else { return nil }
        let key = SubjectNameSimilarity.key(for: trimmedQuery)
        return subjects.contains { SubjectNameSimilarity.key(for: $0.name) == key } ? nil : trimmedQuery
    }

    private static func fold(_ text: String) -> String {
        SubjectNameSimilarity.fold(text)
    }
}

import SwiftUI

/// One subject's courses, grouped by university, with the three fixes: change a course's subject, rename the
/// subject, merge it into another. The screen reads the subject from the shared view model, so it follows every
/// reload and closes itself when the subject is gone (merged).
struct SubjectDetailView: View {
    let subjectId: String
    let viewModel: SubjectMappingViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var changing: SubjectCourse?
    @State private var isPickingMerge = false
    @State private var isRenaming = false

    var body: some View {
        Group {
            if let subject = viewModel.subject(id: subjectId) {
                detail(subject)
            } else {
                EmptyStateView(title: "Ders bulunamadı", systemImage: "books.vertical", message: "Liste yenilenmiş olabilir.")
            }
        }
        .navigationTitle(viewModel.subject(id: subjectId)?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: viewModel.subject(id: subjectId) == nil) { _, isGone in
            if isGone { dismiss() }
        }
    }

    private func detail(_ subject: AdminSubject) -> some View {
        List {
            if let error = viewModel.actionError {
                Section {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("subjects.error")
                }
            }
            Section {
                LabeledContent("Dersler", value: "\(subject.courseCount)")
                LabeledContent("Sorular", value: "\(subject.questionCount)")
                if let match = viewModel.possibleMatch(for: subject.id) {
                    Label("Olası eşleşme: \(match.name)", systemImage: "arrow.triangle.merge")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("subjects.possibleMatch")
                }
            } footer: {
                Text("Bir dersin konusunu değiştirince o dersin yayınlanmış soruları ve soru havuzları yeni konuya taşınır.")
            }
            ForEach(Self.groups(of: subject.courses), id: \.universityId) { group in
                Section(group.universityName) {
                    ForEach(group.courses) { course in
                        courseRow(course)
                    }
                }
            }
        }
        .accessibilityIdentifier("subjects.detail")
        .overlay { if viewModel.isWorking { ProgressView().controlSize(.large) } }
        .disabled(viewModel.isWorking)
        .toolbar { toolbar(subject) }
        .modifier(SubjectDialogs(
            subject: subject, viewModel: viewModel, changing: $changing, isPickingMerge: $isPickingMerge, isRenaming: $isRenaming
        ))
    }

    private func courseRow(_ course: SubjectCourse) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(course.name)
                    .font(.body)
                if !course.place.isEmpty {
                    Text(course.place)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text("\(course.questionCount) soru")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Değiştir") { changing = course }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("subjects.course.change")
                .accessibilityLabel("\(course.name) dersinin konusunu değiştir")
        }
        .padding(.vertical, 2)
    }

    @ToolbarContentBuilder
    private func toolbar(_ subject: AdminSubject) -> some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button("Yeniden adlandır", systemImage: "pencil") { isRenaming = true }
                    .accessibilityIdentifier("subjects.rename")
                Button("Başka derse birleştir", systemImage: "arrow.triangle.merge") { isPickingMerge = true }
                    .accessibilityIdentifier("subjects.merge")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("Ders işlemleri")
            .accessibilityIdentifier("subjects.menu")
        }
    }

    /// The courses grouped by university, universities and courses by name.
    private static func groups(of courses: [SubjectCourse]) -> [CourseGroup] {
        Dictionary(grouping: courses, by: \.universityId)
            .map { id, courses in
                CourseGroup(
                    universityId: id,
                    universityName: courses.first?.universityName ?? "",
                    courses: courses.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
                )
            }
            .sorted { $0.universityName.localizedCompare($1.universityName) == .orderedAscending }
    }

    private struct CourseGroup {
        let universityId: String
        let universityName: String
        let courses: [SubjectCourse]
    }
}

/// The detail screen's pickers, rename field and merge confirmation.
private struct SubjectDialogs: ViewModifier {
    let subject: AdminSubject
    let viewModel: SubjectMappingViewModel
    @Binding var changing: SubjectCourse?
    @Binding var isPickingMerge: Bool
    @Binding var isRenaming: Bool

    @State private var mergeTarget: AdminSubject?
    @State private var isConfirmingMerge = false
    @State private var newName = ""

    /// Every subject but this one: where a course or this subject can go.
    private var otherSubjects: [AdminSubject] {
        (viewModel.state.value ?? []).filter { $0.id != subject.id }
    }

    func body(content: Content) -> some View {
        content
            .sheet(item: $changing) { course in
                SubjectPickerSheet(title: "Yeni konu seç", subjects: otherSubjects, allowsNew: true) { pick in
                    changing = nil
                    Task { await change(course, to: pick) }
                }
            }
            .sheet(isPresented: $isPickingMerge, onDismiss: { isConfirmingMerge = mergeTarget != nil }, content: {
                SubjectPickerSheet(title: "Birleştirilecek ders", subjects: otherSubjects, allowsNew: false) { pick in
                    if case let .existing(target) = pick { mergeTarget = target }
                    isPickingMerge = false
                }
            })
            .onChange(of: isRenaming) { _, isShown in
                if isShown { newName = subject.name }
            }
            .alert("Dersi yeniden adlandır", isPresented: $isRenaming) {
                TextField("Ders adı", text: $newName)
                    .accessibilityIdentifier("subjects.rename.field")
                Button("Kaydet") { Task { _ = await viewModel.rename(subject, to: newName) } }
                    .accessibilityIdentifier("subjects.rename.confirm")
                Button("Vazgeç", role: .cancel) {}
            }
            .alert("Dersler birleştirilsin mi?", isPresented: $isConfirmingMerge, presenting: mergeTarget) { target in
                Button("Birleştir", role: .destructive) {
                    mergeTarget = nil
                    Task { _ = await viewModel.merge(subject, into: target) }
                }
                .accessibilityIdentifier("subjects.merge.confirm")
                Button("Vazgeç", role: .cancel) { mergeTarget = nil }
            } message: { target in
                Text(
                    "“\(subject.name)”, “\(target.name)” içine birleştirilecek: \(subject.courseCount) dersi ve "
                        + "\(subject.questionCount) sorusu “\(target.name)” konusuna taşınır, soru havuzları güncellenir ve "
                        + "“\(subject.name)” silinir."
                )
            }
    }

    private func change(_ course: SubjectCourse, to pick: SubjectPick) async {
        switch pick {
        case let .existing(target): _ = await viewModel.setCourseSubject(course, to: .existing(id: target.id))
        case let .new(name): _ = await viewModel.setCourseSubject(course, to: .new(name: name))
        }
    }
}

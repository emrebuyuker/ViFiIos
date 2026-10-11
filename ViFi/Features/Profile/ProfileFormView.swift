import SwiftUI

/// The editable profile fields, shared by the completion gate and the account editor. Rendered as a set of
/// `Section`s, so it is dropped straight into a `Form` that lives inside a navigation stack (the catalog
/// pickers are pushed onto that stack).
struct ProfileFormView: View {
    @Bindable var viewModel: ProfileFormViewModel

    var body: some View {
        Group {
            Section("Kişisel Bilgiler") {
                TextField("Ad", text: $viewModel.name)
                    .textContentType(.givenName)
                    .autocorrectionDisabled()
                    .disabled(viewModel.isWorking)
                    .accessibilityIdentifier("profile.name")

                TextField("Soyad", text: $viewModel.surname)
                    .textContentType(.familyName)
                    .autocorrectionDisabled()
                    .disabled(viewModel.isWorking)
                    .accessibilityIdentifier("profile.surname")
            }

            Section("Eğitim") {
                catalogRow(
                    title: "Üniversite",
                    selection: $viewModel.university,
                    options: viewModel.catalog.universities,
                    identifier: "profile.university"
                )
                catalogRow(
                    title: "Fakülte",
                    selection: $viewModel.faculty,
                    options: viewModel.catalog.faculties,
                    identifier: "profile.faculty"
                )
                catalogRow(
                    title: "Bölüm",
                    selection: $viewModel.department,
                    options: viewModel.catalog.departments,
                    identifier: "profile.department"
                )
            }

            Section("Cinsiyet") {
                Picker("Cinsiyet", selection: $viewModel.gender) {
                    ForEach(Gender.allCases) { gender in
                        Text(gender.label).tag(Optional(gender))
                    }
                }
                .pickerStyle(.segmented)
                .disabled(viewModel.isWorking)
                .accessibilityIdentifier("profile.gender")
            }

            Section {
                LabeledContent("Telefon") {
                    Text(verbatim: viewModel.formattedPhoneNumber)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("profile.phone")
            } footer: {
                Text("Numaran giriş sırasında doğrulandı ve değiştirilemez.")
            }
        }
    }

    /// A row that pushes the catalog picker for `identifier` and shows the current value.
    private func catalogRow(
        title: LocalizedStringKey,
        selection: Binding<CatalogSelection>,
        options: [CatalogItem],
        identifier: String
    ) -> some View {
        let value = selection.wrappedValue.name
        return NavigationLink {
            CatalogPickerView(
                title: title,
                options: options,
                accessibilityPrefix: identifier,
                selection: selection
            )
        } label: {
            LabeledContent(title) {
                Text(value.isEmpty ? String(localized: "Seç") : value)
                    .foregroundStyle(value.isEmpty ? .secondary : .primary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .disabled(viewModel.isWorking)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(Text(value))
    }
}

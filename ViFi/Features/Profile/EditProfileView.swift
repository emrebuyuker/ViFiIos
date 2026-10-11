import SwiftUI

/// Edits the signed-in user's profile from the account sheet. Pushed onto the account's navigation stack;
/// saving updates the shared profile and pops back.
struct EditProfileView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let user: AuthUser

    var body: some View {
        EditProfileScreen(
            user: user,
            existing: environment.profile.profile,
            profileService: environment.profileService,
            catalog: environment.catalog,
            onSaved: { profile in
                environment.profile.update(profile)
                dismiss()
            }
        )
        .onAppear { environment.analytics.track(.screenView(name: "EditProfile")) }
    }
}

/// The screen itself, owning its view model for the lifetime of the editor.
private struct EditProfileScreen: View {
    @State private var viewModel: ProfileFormViewModel

    init(
        user: AuthUser,
        existing: UserProfile?,
        profileService: any ProfileServicing,
        catalog: UniversityCatalog,
        onSaved: @escaping (UserProfile) -> Void
    ) {
        _viewModel = State(initialValue: ProfileFormViewModel(
            user: user,
            existing: existing,
            profileService: profileService,
            catalog: catalog,
            onSaved: onSaved
        ))
    }

    var body: some View {
        Form {
            ProfileFormView(viewModel: viewModel)

            if let message = viewModel.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("editProfile.error")
                }
            }
        }
        .navigationTitle("Profili Düzenle")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .animation(.smooth, value: viewModel.errorMessage)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Kaydet") {
                    viewModel.save()
                }
                .disabled(!viewModel.canSave)
                .accessibilityIdentifier("editProfile.save")
            }
        }
    }
}

#if DEBUG
#Preview("Profili Düzenle") {
    NavigationStack {
        EditProfileView(user: AuthUser(id: "preview", phoneNumber: "+905321234567"))
            .environment(AppEnvironment.mock())
    }
}
#endif

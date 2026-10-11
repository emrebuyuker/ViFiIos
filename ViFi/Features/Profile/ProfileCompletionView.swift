import SwiftUI

/// The blocking screen shown after sign-in when the user has no profile yet: they must fill it in before the
/// archive opens. They can still sign out from here, so nobody is trapped.
struct ProfileCompletionView: View {
    @Environment(AppEnvironment.self) private var environment
    let user: AuthUser

    var body: some View {
        ProfileCompletionScreen(
            user: user,
            profileService: environment.profileService,
            catalog: environment.catalog,
            auth: environment.auth,
            onSaved: { environment.profile.update($0) }
        )
        .onAppear { environment.analytics.track(.screenView(name: "ProfileCompletion")) }
    }
}

/// The screen itself, owning its view model for the lifetime of the gate.
private struct ProfileCompletionScreen: View {
    @State private var viewModel: ProfileFormViewModel
    private let auth: any AuthServicing

    init(
        user: AuthUser,
        profileService: any ProfileServicing,
        catalog: UniversityCatalog,
        auth: any AuthServicing,
        onSaved: @escaping (UserProfile) -> Void
    ) {
        _viewModel = State(initialValue: ProfileFormViewModel(
            user: user,
            existing: nil,
            profileService: profileService,
            catalog: catalog,
            onSaved: onSaved
        ))
        self.auth = auth
    }

    var body: some View {
        NavigationStack {
            Form {
                headerSection
                ProfileFormView(viewModel: viewModel)

                if let message = viewModel.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("profile.error")
                    }
                }
            }
            .navigationTitle("Profilini Tamamla")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .animation(.smooth, value: viewModel.errorMessage)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Çıkış Yap") {
                        try? auth.signOut()
                    }
                    .disabled(viewModel.isWorking)
                    .accessibilityIdentifier("profile.signOut")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kaydet") {
                        viewModel.save()
                    }
                    .disabled(!viewModel.canSave)
                    .accessibilityIdentifier("profile.save")
                }
            }
        }
    }

    private var headerSection: some View {
        Section {
            VStack(spacing: 6) {
                Text("Son bir adım")
                    .font(.headline)
                Text("Arşive ulaşmak için birkaç bilgini tamamla. Bu bilgiler profilinde saklanır.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
        .listRowBackground(Color.clear)
    }
}

#if DEBUG
#Preview("Profili Tamamla") {
    ProfileCompletionView(user: AuthUser(id: "preview", phoneNumber: "+905321234567"))
        .environment(AppEnvironment.mock(arguments: [LaunchArgument.profileIncomplete]))
}
#endif

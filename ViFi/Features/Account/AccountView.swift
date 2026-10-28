import SwiftUI

/// The signed-in account, presented as a sheet from the home screen: phone number, sign out, delete.
struct AccountView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        // Signing out or deleting replaces the whole archive (and this sheet) with the login screen.
        if let user = environment.session.user {
            AccountScreen(
                user: user,
                auth: environment.auth,
                profileName: environment.profile.profile?.fullName,
                // Removes the server-side profile before the account is deleted, so nothing is left orphaned.
                deleteUserData: { [profileService = environment.profileService] in
                    try await profileService.deleteProfile(uid: user.id)
                },
                // Deleting the account wipes the user's cached exam files from the device.
                onDeleted: { [fileLoader = environment.fileLoader, analytics = environment.analytics] in
                    analytics.track(.accountDeleted)
                    await fileLoader.purge()
                }
            )
        }
    }
}

/// The screen itself, owning its view model for the lifetime of the sheet.
private struct AccountScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var environment
    @State private var viewModel: AccountViewModel
    @State private var isConfirmingSignOut = false
    @State private var isConfirmingDeletion = false
    @State private var isShowingPaywall = false
    @Environment(\.openURL) private var openURL
    /// Whether the signed-in user is an admin (reveals the moderation tools); resolved on appear.
    @State private var isAdmin = false
    @FocusState private var isCodeFocused: Bool
    /// The signed-in user, for the edit-profile link (the view model already holds it too).
    private let user: AuthUser
    /// The current profile's display name, shown on the edit-profile row.
    private let profileName: String?

    init(
        user: AuthUser,
        auth: any AuthServicing,
        profileName: String?,
        deleteUserData: @escaping @MainActor () async throws -> Void,
        onDeleted: @escaping @MainActor () async -> Void
    ) {
        _viewModel = State(initialValue: AccountViewModel(
            user: user, auth: auth, deleteUserData: deleteUserData, onDeleted: onDeleted
        ))
        self.user = user
        self.profileName = profileName
    }

    var body: some View {
        NavigationStack {
            List {
                profileSection
                premiumSection
                if !environment.subscription.isSubscribed {
                    coinSection
                }
                if isAdmin {
                    moderationSection
                }
                phoneSection
                signOutSection
                deleteSection

                if viewModel.isReverifying {
                    reverificationSection
                }

                if let message = viewModel.errorMessage {
                    Section {
                        Label(message, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("account.error")
                    }
                }
            }
            .accessibilityIdentifier("account.sheet")
            .animation(.smooth, value: viewModel.isReverifying)
            .animation(.smooth, value: viewModel.errorMessage)
            .animation(.smooth, value: isAdmin)
            .task { isAdmin = await environment.auth.isCurrentUserAdmin() }
            .navigationTitle("Hesap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bitti") {
                        dismiss()
                    }
                    // Closing mid-deletion would strand a re-verification code with no screen to enter it.
                    .disabled(viewModel.isWorking)
                    .accessibilityIdentifier("account.done")
                }
            }
            .sheet(isPresented: $isShowingPaywall) {
                PaywallView()
            }
            .confirmationDialog("Çıkış yapılsın mı?", isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
                Button("Çıkış Yap", role: .destructive) {
                    viewModel.signOut()
                    if viewModel.errorMessage == nil {
                        environment.analytics.track(.signedOut)
                    }
                }
                .accessibilityIdentifier("account.signOut.confirm")
                Button("Vazgeç", role: .cancel) {}
            } message: {
                Text("Arşive tekrar ulaşmak için numaranı yeniden doğrulaman gerekir.")
            }
            .alert("Hesabın kalıcı olarak silinsin mi?", isPresented: $isConfirmingDeletion) {
                Button("Hesabı Sil", role: .destructive) {
                    viewModel.deleteAccount()
                }
                .accessibilityIdentifier("account.delete.confirm")
                Button("Vazgeç", role: .cancel) {}
            } message: {
                Text("""
                    Hesabın ve telefon numaran ViFi'den kalıcı olarak silinir; bu işlem geri alınamaz. \
                    Uygulamayı yeniden kullanmak istersen numaranı baştan doğrulaman gerekir.
                    """)
            }
            .onChange(of: viewModel.isReverifying) { _, isReverifying in
                isCodeFocused = isReverifying
            }
            .interactiveDismissDisabled(viewModel.isWorking)
        }
    }

    // MARK: - Sections

    private var profileSection: some View {
        Section {
            NavigationLink {
                EditProfileView(user: user)
            } label: {
                HStack(spacing: 14) {
                    IconBadge(systemName: "person.text.rectangle.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Profil")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(profileName ?? String(localized: "Profili Düzenle"))
                            .font(.headline)
                    }
                }
                .padding(.vertical, 4)
            }
            .disabled(viewModel.isWorking)
            .accessibilityIdentifier("account.editProfile")
        }
    }

    private var premiumSection: some View {
        AccountPremiumSection(
            isSubscribed: environment.subscription.isSubscribed,
            onUpgrade: { isShowingPaywall = true },
            onManage: { openURL(PremiumLegal.manageSubscriptionsURL) }
        )
    }

    private var coinSection: some View {
        Section {
            HStack(spacing: 14) {
                IconBadge(systemName: "bitcoinsign.circle.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Coin bakiyen")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(environment.wallet.balance, format: .number)
                        .font(.headline.monospacedDigit())
                        .contentTransition(.numericText())
                }
                Spacer()
            }
            .padding(.vertical, 4)
            .animation(.smooth, value: environment.wallet.balance)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Coin bakiyen")
            .accessibilityValue(Text(environment.wallet.balance, format: .number))
            .accessibilityIdentifier("account.coinBalance")
        } footer: {
            Text("Onaylanan sınav yüklemelerinden coin kazanırsın.")
        }
    }

    private var moderationSection: some View {
        Section {
            NavigationLink {
                ModerationView()
            } label: {
                HStack(spacing: 14) {
                    IconBadge(systemName: "checklist")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Moderasyon")
                            .font(.headline)
                        Text("Bekleyen gönderimleri incele ve onayla")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .accessibilityIdentifier("account.moderation")
        }
    }

    private var phoneSection: some View {
        Section {
            HStack(spacing: 14) {
                IconBadge(systemName: "person.crop.circle.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Telefon numarası")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(verbatim: viewModel.formattedPhoneNumber)
                        .font(.headline.monospacedDigit())
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("account.phone")
        }
    }

    private var signOutSection: some View {
        Section {
            Button("Çıkış Yap", systemImage: "rectangle.portrait.and.arrow.right") {
                isConfirmingSignOut = true
            }
            .disabled(viewModel.isWorking)
            .accessibilityIdentifier("account.signOut")
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                isConfirmingDeletion = true
            } label: {
                HStack {
                    Label("Hesabı Sil", systemImage: "trash")
                        // In a custom label the icon would otherwise take the accent colour.
                        .foregroundStyle(.red)
                    Spacer()
                    if viewModel.isWorking && !viewModel.isReverifying {
                        ProgressView()
                    }
                }
            }
            .disabled(viewModel.isWorking || viewModel.isReverifying)
            .accessibilityIdentifier("account.delete")
        } footer: {
            Text("Hesabını sildiğinde oturumun kapanır ve hesabın kalıcı olarak silinir.")
        }
    }

    private var reverificationSection: some View {
        Section {
            TextField(
                text: Binding(get: { viewModel.codeText }, set: { viewModel.updateCode($0) }),
                prompt: Text(verbatim: "000000")
            ) {
                Text("Doğrulama kodu")
            }
            .font(.title3.monospacedDigit())
            .kerning(6)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .focused($isCodeFocused)
            .disabled(viewModel.isWorking)
            .accessibilityIdentifier("account.reauth.code")

            Button(role: .destructive) {
                viewModel.confirmReverification()
            } label: {
                HStack {
                    Text("Doğrula ve Hesabı Sil")
                    Spacer()
                    if viewModel.isWorking {
                        ProgressView()
                    }
                }
            }
            .disabled(!viewModel.canConfirmReverification)
            .accessibilityIdentifier("account.reauth.verify")

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = viewModel.resendCooldownRemaining(at: context.date)
                Button {
                    viewModel.resendCode()
                } label: {
                    if remaining > 0 {
                        Text("Kodu tekrar gönder (\(remaining) sn)")
                            .monospacedDigit()
                    } else {
                        Text("Kodu tekrar gönder")
                    }
                }
                .disabled(!viewModel.canResendCode(at: context.date))
                .accessibilityIdentifier("account.reauth.resend")
            }

            Button("Vazgeç") {
                viewModel.cancelReverification()
            }
            .disabled(viewModel.isWorking)
            .accessibilityIdentifier("account.reauth.cancel")
        } header: {
            Text("Numaranı Doğrula")
        } footer: {
            Text("Güvenliğin için \(viewModel.formattedPhoneNumber) numarasına gönderilen 6 haneli kodu gir.")
        }
    }
}

/// The account's premium row: an upgrade prompt when not subscribed, or the active status with a manage link.
private struct AccountPremiumSection: View {
    let isSubscribed: Bool
    let onUpgrade: () -> Void
    let onManage: () -> Void

    var body: some View {
        if isSubscribed {
            Section {
                HStack(spacing: 14) {
                    IconBadge(systemName: "crown.fill", tint: .orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ViFi Premium")
                            .font(.headline)
                        Text("Tüm sınavlar açık")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("account.premium.active")

                Button("Aboneliği Yönet", action: onManage)
                    .accessibilityIdentifier("account.premium.manage")
            } footer: {
                Text("Aboneliğini App Store ayarlarından yönetebilir veya iptal edebilirsin.")
            }
        } else {
            Section {
                Button(action: onUpgrade) {
                    HStack(spacing: 14) {
                        IconBadge(systemName: "crown.fill", tint: .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("ViFi Premium'a Geç")
                                .font(.headline)
                            Text("Tüm sınavlara sınırsız eriş")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("account.premium.upgrade")
            }
        }
    }
}

#if DEBUG
#Preview("Hesap") {
    AccountView()
        .environment(AppEnvironment.mock())
        .environment(Router())
}
#endif

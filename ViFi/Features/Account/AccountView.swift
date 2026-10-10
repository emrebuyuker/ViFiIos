import SwiftUI

/// The signed-in account, presented as a sheet from the home screen: phone number, sign out, delete.
struct AccountView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        // Signing out or deleting replaces the whole archive (and this sheet) with the login screen.
        if let user = environment.session.user {
            AccountScreen(user: user, auth: environment.auth)
        }
    }
}

/// The screen itself, owning its view model for the lifetime of the sheet.
private struct AccountScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: AccountViewModel
    @State private var isConfirmingSignOut = false
    @State private var isConfirmingDeletion = false
    @FocusState private var isCodeFocused: Bool

    init(user: AuthUser, auth: any AuthServicing) {
        _viewModel = State(initialValue: AccountViewModel(user: user, auth: auth))
    }

    var body: some View {
        NavigationStack {
            List {
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
            .confirmationDialog("Çıkış yapılsın mı?", isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
                Button("Çıkış Yap", role: .destructive) {
                    viewModel.signOut()
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

#if DEBUG
#Preview("Hesap") {
    AccountView()
        .environment(AppEnvironment.mock())
        .environment(Router())
}
#endif

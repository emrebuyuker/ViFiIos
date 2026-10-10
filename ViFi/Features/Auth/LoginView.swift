import SwiftUI

/// The sign-in screen, shown whenever nobody is signed in: phone number, then the SMS code.
struct LoginView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        LoginScreen(auth: environment.auth)
            .onAppear { environment.analytics.track(.screenView(name: "Login")) }
    }
}

/// The screen itself. Split from `LoginView` so the view model can be created from the environment's
/// auth service and then owned by `@State` for the lifetime of the screen.
private struct LoginScreen: View {
    @State private var viewModel: LoginViewModel
    @State private var isPhoneFocused = false
    @FocusState private var isCodeFocused: Bool

    init(auth: any AuthServicing) {
        _viewModel = State(initialValue: LoginViewModel(auth: auth))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                LoginHeader(step: viewModel.step)

                VStack(spacing: 16) {
                    switch viewModel.step {
                    case .phone:
                        phoneStep
                    case .code:
                        codeStep
                    }
                }
                .frame(maxWidth: 440)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground))
        .animation(.smooth, value: viewModel.step)
        .animation(.smooth, value: viewModel.errorMessage)
        .onChange(of: viewModel.step) { _, step in
            if case .code = step {
                isPhoneFocused = false
                isCodeFocused = true
            }
        }
        .onChange(of: viewModel.isWorking) { _, isWorking in
            // The field is disabled while verifying; after a failed attempt it is ready for the next code.
            if !isWorking, case .code = viewModel.step {
                isCodeFocused = true
            }
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var phoneStep: some View {
        HStack(spacing: 12) {
            Text(verbatim: PhoneNumber.countryCode)
                .font(.title3.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Divider()
                .frame(height: 28)

            PhoneNumberTextField(
                text: Binding(get: { viewModel.phoneText }, set: { viewModel.updatePhoneText($0) }),
                isFocused: $isPhoneFocused
            )
                .disabled(viewModel.isWorking)
                .accessibilityLabel("Telefon numarası, \(PhoneNumber.countryCode)")
                .accessibilityIdentifier("login.phone")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14, style: .continuous))

        errorMessage

        PrimaryActionButton(title: "Kod Gönder", isWorking: viewModel.isWorking) {
            isPhoneFocused = false
            viewModel.sendCode()
        }
        .disabled(!viewModel.canSendCode)
        .accessibilityIdentifier("login.sendCode")

        Text("Numarana tek kullanımlık bir doğrulama kodu SMS ile gönderilir. Standart SMS ücretleri uygulanabilir.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var codeStep: some View {
        // Edits go straight to the view model, so the sixth digit always submits (no coalesced `onChange`).
        TextField(
            text: Binding(get: { viewModel.codeText }, set: { viewModel.updateCode($0) }),
            prompt: Text(verbatim: "000000")
        ) {
            Text("Doğrulama kodu")
        }
        .font(.title.monospacedDigit().weight(.semibold))
        .kerning(8)
        .multilineTextAlignment(.center)
        .keyboardType(.numberPad)
        .textContentType(.oneTimeCode)
        .focused($isCodeFocused)
        .disabled(viewModel.isWorking)
        .padding(.vertical, 14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14, style: .continuous))
        .accessibilityLabel("Doğrulama kodu")
        .accessibilityIdentifier("login.code")

        errorMessage

        PrimaryActionButton(title: "Doğrula", isWorking: viewModel.isWorking) {
            isCodeFocused = false
            viewModel.verifyCode()
        }
        .disabled(!viewModel.canVerify)
        .accessibilityIdentifier("login.verify")

        HStack {
            ResendCodeButton(viewModel: viewModel)
            Spacer(minLength: 12)
            Button("Numarayı değiştir") {
                viewModel.changeNumber()
                isPhoneFocused = true
            }
            .disabled(viewModel.isWorking)
            .accessibilityIdentifier("login.changeNumber")
        }
        .font(.subheadline)
    }

    @ViewBuilder
    private var errorMessage: some View {
        if let message = viewModel.errorMessage {
            Label(message, systemImage: "exclamationmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("login.error")
                .transition(.opacity)
        }
    }
}

// MARK: - Components

/// Logo and the step's title and explanation.
private struct LoginHeader: View {
    let step: LoginViewModel.Step

    @ScaledMetric(relativeTo: .largeTitle) private var logoSize: CGFloat = 84

    var body: some View {
        VStack(spacing: 10) {
            Image("Logo")
                .resizable()
                .scaledToFit()
                .frame(width: clampedLogoSize, height: clampedLogoSize)
                .clipShape(.rect(cornerRadius: clampedLogoSize * 0.225, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                .accessibilityHidden(true)
                .padding(.bottom, 6)

            switch step {
            case .phone:
                Text("Giriş Yap")
                    .font(.largeTitle.bold())
                Text("Sınav arşivine ulaşmak için cep telefonu numaranı doğrula.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            case let .code(phoneNumber):
                Text("Kodu Gir")
                    .font(.largeTitle.bold())
                Text("\(phoneNumber.formatted) numarasına gönderilen 6 haneli kodu gir.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var clampedLogoSize: CGFloat {
        min(logoSize, 120)
    }
}

/// A full-width prominent button that shows a spinner instead of its title while working.
private struct PrimaryActionButton: View {
    let title: LocalizedStringKey
    let isWorking: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                // Black on the brand orange: white text would fall below 3:1 contrast.
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.black)
                    .opacity(isWorking ? 0 : 1)
                if isWorking {
                    ProgressView()
                        .tint(.black)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .accessibilityLabel(Text(title))
        .accessibilityValue(isWorking ? Text("Lütfen bekle") : Text(verbatim: ""))
    }
}

/// "Kodu tekrar gönder", counting down the cooldown once a second.
private struct ResendCodeButton: View {
    let viewModel: LoginViewModel

    var body: some View {
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
            .accessibilityIdentifier("login.resend")
        }
    }
}

#if DEBUG
#Preview("Giriş") {
    LoginView()
        .environment(AppEnvironment.mock(arguments: [LaunchArgument.signedOut]))
        .environment(Router())
}
#endif

import SwiftUI

/// The result of buying a single exam with money, so the sheet can open it, stay put, or show an error.
enum ExamPurchaseOutcome {
    case unlocked
    case cancelled
    case failed(String)
}

/// Shown when a user taps a locked exam: offers to unlock it with coins, or — when the balance is too low —
/// points them to adding exams to earn coins. The debit itself happens server-side (the `unlock` closure calls
/// the Cloud Function).
struct ExamUnlockSheet: View {
    let examName: String
    let balance: Int
    /// Spends coins to unlock; returns an error message on failure, `nil` on success.
    let unlock: () async -> String?
    /// Buys this single exam with money; the outcome distinguishes success, cancellation and failure.
    let purchaseWithMoney: () async -> ExamPurchaseOutcome
    /// Called after a successful unlock (coins or money), so the caller can open the exam.
    let onUnlocked: () -> Void
    /// Called to let the user earn coins (opens the add-exam flow).
    let onEarnCoins: () -> Void
    /// Called when the user chooses to unlock everything with a subscription (opens the paywall).
    let onGoPremium: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isWorking = false
    @State private var isPurchasing = false
    @State private var errorMessage: String?

    /// Any action in progress (coin unlock or money purchase) blocks the others and dismissal.
    private var isBusy: Bool { isWorking || isPurchasing }

    private var canAfford: Bool {
        balance >= ExamLock.unlockCost
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.orange)
                    .padding(.top, 8)

                VStack(spacing: 6) {
                    Text(examName)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    Text("Bu sınav kilitli.")
                        .foregroundStyle(.secondary)
                }

                if canAfford {
                    affordContent
                } else {
                    earnContent
                }

                moneyUnlockOption

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("exam.unlock.error")
                }

                Spacer(minLength: 0)

                Divider()
                Button {
                    dismiss()
                    onGoPremium()
                } label: {
                    Label("Tek tek açmak yerine Premium'a geç", systemImage: "crown.fill")
                        .font(.subheadline.weight(.medium))
                }
                .disabled(isBusy)
                .accessibilityIdentifier("exam.unlock.premium")
            }
            .padding()
            .navigationTitle("Sınavı Aç")
            .navigationBarTitleDisplayMode(.inline)
            .animation(.smooth, value: errorMessage)
            .interactiveDismissDisabled(isBusy)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }
                        .disabled(isBusy)
                }
            }
        }
        .presentationDetents([.medium])
        .accessibilityIdentifier("exam.unlock.sheet")
    }

    private var affordContent: some View {
        VStack(spacing: 14) {
            Label("\(ExamLock.unlockCost) coin · Bakiyen: \(balance)", systemImage: "bitcoinsign.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                performUnlock()
            } label: {
                HStack {
                    Spacer()
                    if isWorking {
                        ProgressView().tint(.black)
                    } else {
                        Text("Aç (\(ExamLock.unlockCost) coin)")
                            .fontWeight(.semibold)
                            .foregroundStyle(.black)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isBusy)
            .accessibilityIdentifier("exam.unlock.confirm")

            Text("Açtığın sınav hesabında kalıcı olur, bir daha kilitlenmez.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var earnContent: some View {
        VStack(spacing: 14) {
            Text("Coin kazanmak için uygulamada olmayan sınavları ekleyebilirsin.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                onEarnCoins()
            } label: {
                HStack {
                    Spacer()
                    Text("Sınav Ekle")
                        .fontWeight(.semibold)
                        .foregroundStyle(.black)
                    Spacer()
                }
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("exam.unlock.earn")
        }
    }

    /// Buying just this exam with money — an alternative to coins, always available. The App Store sheet shows
    /// the price; a subscription (via the Premium link below) is the better deal for more than a couple of exams.
    private var moneyUnlockOption: some View {
        VStack(spacing: 6) {
            Text("veya")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                performPurchase()
            } label: {
                HStack {
                    Spacer()
                    if isPurchasing {
                        ProgressView()
                    } else {
                        Label("Parayla bu sınavı aç", systemImage: "creditcard")
                            .fontWeight(.medium)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.bordered)
            .disabled(isBusy)
            .accessibilityIdentifier("exam.unlock.buy")
        }
    }

    private func performPurchase() {
        errorMessage = nil
        isPurchasing = true
        Task {
            let outcome = await purchaseWithMoney()
            isPurchasing = false
            switch outcome {
            case .unlocked:
                dismiss()
                onUnlocked()
            case .cancelled:
                break
            case let .failed(message):
                errorMessage = message
            }
        }
    }

    private func performUnlock() {
        errorMessage = nil
        isWorking = true
        Task {
            let error = await unlock()
            isWorking = false
            if let error {
                errorMessage = error
            } else {
                dismiss()
                onUnlocked()
            }
        }
    }
}

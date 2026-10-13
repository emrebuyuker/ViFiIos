import SwiftUI

/// Shown when a user taps a locked exam: offers to unlock it with coins, or — when the balance is too low —
/// points them to adding exams to earn coins. The debit itself happens server-side (the `unlock` closure calls
/// the Cloud Function).
struct ExamUnlockSheet: View {
    let examName: String
    let balance: Int
    /// Spends coins to unlock; returns an error message on failure, `nil` on success.
    let unlock: () async -> String?
    /// Called after a successful unlock, so the caller can open the exam.
    let onUnlocked: () -> Void
    /// Called to let the user earn coins (opens the add-exam flow).
    let onEarnCoins: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isWorking = false
    @State private var errorMessage: String?

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

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("exam.unlock.error")
                }

                Spacer(minLength: 0)
            }
            .padding()
            .navigationTitle("Sınavı Aç")
            .navigationBarTitleDisplayMode(.inline)
            .animation(.smooth, value: errorMessage)
            .interactiveDismissDisabled(isWorking)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Kapat") { dismiss() }
                        .disabled(isWorking)
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
            .disabled(isWorking)
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

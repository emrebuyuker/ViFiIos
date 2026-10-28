import SwiftUI

/// A compact pill showing the signed-in user's current coin balance, for the toolbars across the app.
///
/// Reads the live balance from `CoinWalletStore`, so it updates everywhere at once when an approval credits
/// the user. The number animates between values. Hidden entirely while a premium subscription is active: a
/// subscriber has the whole archive unlocked and the coin economy does not apply to them.
struct CoinBalanceBadge: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        if !environment.subscription.isSubscribed {
            badge
        }
    }

    private var badge: some View {
        let balance = environment.wallet.balance
        return HStack(spacing: 4) {
            Image(systemName: "bitcoinsign.circle.fill")
                .foregroundStyle(.orange)
            Text(balance, format: .number)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.orange.opacity(0.14), in: .capsule)
        // Keep the intrinsic width; without this the toolbar compresses the number to nothing on iOS 26.
        .fixedSize()
        .animation(.smooth, value: balance)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Coin bakiyen")
        .accessibilityValue(Text(balance, format: .number))
        .accessibilityIdentifier("coin.balance")
    }
}

#if DEBUG
#Preview("Coin rozeti") {
    NavigationStack {
        Text(verbatim: "İçerik")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    CoinBalanceBadge()
                }
            }
    }
    .environment(AppEnvironment.mock())
}
#endif

import SwiftUI

/// The premium subscription screen: shows the plans, buys one, and restores past purchases. Presented as a
/// sheet from the account screen and from a locked exam. An active subscription unlocks the whole archive.
struct PaywallView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// The purchasable plans. `nil` while loading; empty after a failed load (the retry shows then).
    @State private var options: [SubscriptionOption]?
    @State private var loadFailed = false
    @State private var selectedID: String?
    @State private var isPurchasing = false
    @State private var isRestoring = false
    @State private var errorMessage: String?

    private var selectedOption: SubscriptionOption? {
        options?.first { $0.id == selectedID }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("ViFi Premium")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Kapat") { dismiss() }
                            .disabled(isPurchasing)
                            .accessibilityIdentifier("paywall.close")
                    }
                }
                .safeAreaInset(edge: .bottom) { purchaseBar }
                .task {
                    environment.analytics.track(.screenView(name: "Paywall"))
                    await loadOptions()
                }
                // A subscription bought here (or restored, or finished from a pending state) closes the paywall.
                .onChange(of: environment.subscription.isSubscribed) { _, isSubscribed in
                    if isSubscribed { dismiss() }
                }
        }
        .accessibilityIdentifier("paywall.sheet")
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                benefits
                planList
                legalFooter
            }
            .padding()
            .padding(.bottom, 8)
        }
        .animation(.smooth, value: options)
        .animation(.smooth, value: errorMessage)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            IconBadge(systemName: "crown.fill", tint: .orange, size: 56)
            Text("Tüm sınavlara sınırsız eriş")
                .font(.title2.bold())
            Text("Premium ile her dersteki bütün sınavlar kilitsiz açılır; coin biriktirmene gerek kalmaz.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var benefits: some View {
        VStack(alignment: .leading, spacing: 12) {
            benefitRow("Her dersin tüm sınavları açık")
            benefitRow("Kilitli sınav kalmaz, coin gerekmez")
            benefitRow("İstediğin kadar görüntüle ve indir")
            benefitRow("İstediğin zaman iptal et")
        }
    }

    private func benefitRow(_ text: LocalizedStringKey) -> some View {
        Label {
            Text(text).font(.subheadline)
        } icon: {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    // MARK: - Plans

    @ViewBuilder
    private var planList: some View {
        if let options {
            VStack(spacing: 12) {
                ForEach(options) { option in
                    PlanCard(option: option, isSelected: option.id == selectedID) {
                        selectedID = option.id
                    }
                }
            }
        } else if loadFailed {
            VStack(spacing: 12) {
                Text("Abonelik planları yüklenemedi.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Tekrar Dene") { Task { await loadOptions() } }
                    .accessibilityIdentifier("paywall.retry")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
        }
    }

    private var legalFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("""
                Abonelik, dönem sonunda otomatik olarak yenilenir. Yenilemeyi, dönem bitiminden en az 24 saat \
                önce App Store ayarlarından kapatabilirsin.
                """)
            HStack(spacing: 4) {
                Button("Kullanım Koşulları") { openURL(PremiumLegal.termsURL) }
                    .accessibilityIdentifier("paywall.terms")
                Text(verbatim: "·")
                Button("Gizlilik Politikası") { openURL(PremiumLegal.privacyURL) }
                    .accessibilityIdentifier("paywall.privacy")
            }
            .font(.footnote)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: - Purchase bar

    private var purchaseBar: some View {
        VStack(spacing: 10) {
            if let errorMessage {
                Text(errorMessage)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("paywall.error")
            }

            // Custom orange background instead of `.borderedProminent`: a disabled prominent button dims to a
            // dark fill in dark mode, which hid the black spinner while buying. Painting the orange behind the
            // content keeps it orange (black spinner visible) in both modes. Height comes from the content
            // (min 50), so the button never grows to fill the inset.
            Button(action: subscribe) {
                Group {
                    if isPurchasing {
                        ProgressView().tint(.black)
                    } else {
                        Text(subscribeTitle)
                            .fontWeight(.semibold)
                            .foregroundStyle(.black)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(Color.orange, in: .rect(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            // Not disabled while purchasing (that would dim the fill and hide the spinner); re-taps are guarded
            // inside `subscribe()`. Only disabled when there is nothing to buy.
            .disabled(selectedOption == nil || isRestoring)
            .opacity(selectedOption == nil ? 0.5 : 1)
            .accessibilityIdentifier("paywall.subscribe")

            Button(action: restore) {
                if isRestoring {
                    ProgressView()
                } else {
                    Text("Satın alımları geri yükle")
                }
            }
            .font(.footnote)
            .disabled(isPurchasing || isRestoring)
            .accessibilityIdentifier("paywall.restore")
        }
        .padding()
        .background(.bar)
    }

    private var subscribeTitle: String {
        guard let option = selectedOption else { return String(localized: "Abone Ol") }
        return String(localized: "Abone Ol · \(option.displayPrice)")
    }

    // MARK: - Actions

    private func loadOptions() async {
        loadFailed = false
        do {
            try await environment.subscription.loadOptions()
            let loaded = environment.subscription.options
            options = loaded
            // Default to the yearly plan (best value); fall back to the first option.
            if selectedID == nil {
                selectedID = loaded.first { $0.period == .yearly }?.id ?? loaded.first?.id
            }
        } catch {
            loadFailed = true
        }
    }

    private func subscribe() {
        guard let option = selectedOption, !isPurchasing else { return }
        errorMessage = nil
        isPurchasing = true
        Task {
            defer { isPurchasing = false }
            do {
                let result = try await environment.subscription.purchase(option)
                switch result {
                case .success:
                    // The live entitlement stream flips `isSubscribed` and the `onChange` above dismisses.
                    break
                case .cancelled:
                    break
                case .pending:
                    errorMessage = String(localized: "Satın alma onay bekliyor; onaylanınca aboneliğin başlar.")
                }
            } catch {
                errorMessage = (error as? SubscriptionError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func restore() {
        errorMessage = nil
        isRestoring = true
        Task {
            defer { isRestoring = false }
            do {
                try await environment.subscription.restore()
                if !environment.subscription.isSubscribed {
                    errorMessage = String(localized: "Geri yüklenecek bir abonelik bulunamadı.")
                }
            } catch {
                errorMessage = (error as? SubscriptionError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

/// One selectable subscription plan, styled as a bordered card with a selection ring.
private struct PlanCard: View {
    let option: SubscriptionOption
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? .orange : .secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(periodTitle).font(.headline)
                    if let note = periodNote {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(option.displayPrice)
                    .font(.headline.monospacedDigit())
            }
            .padding()
            .background(.background, in: .rect(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Color.orange : Color(.separator), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("paywall.option.\(option.period == .yearly ? "yearly" : "monthly")")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var periodTitle: LocalizedStringKey {
        option.period == .yearly ? "Yıllık" : "Aylık"
    }

    private var periodNote: LocalizedStringKey? {
        option.period == .yearly ? "En avantajlı" : nil
    }
}

/// The legal links shown on the subscription screen (App Store requires both on a paywall).
enum PremiumLegal {
    /// ViFi's published terms of use (hosted on Firebase Hosting); covers the subscription and links Apple's standard EULA.
    static let termsURL = url("https://vifi-831a8.web.app/kullanim-kosullari")
    /// ViFi's published privacy policy (hosted on Firebase Hosting).
    static let privacyURL = url("https://vifi-831a8.web.app/gizlilik")
    /// Opens the user's App Store subscriptions, to manage or cancel.
    static let manageSubscriptionsURL = url("https://apps.apple.com/account/subscriptions")

    /// A non-optional URL from a known-good literal, with a harmless fallback instead of a force unwrap.
    private static func url(_ string: String) -> URL {
        URL(string: string) ?? URL(filePath: "/")
    }
}

#if DEBUG
#Preview("Paywall") {
    PaywallView()
        .environment(AppEnvironment.mock())
}
#endif

import SwiftUI

/// Step 2/2 of the notification permission flow: the campaign consent (Apple 4.5.4). Two equally reachable
/// answers and neither preselected; both write the consent record, so it is clear when and where it was given.
/// Not dismissable by swiping: the user answers, or (after a failed save) closes it.
struct NotificationConsentView: View {
    let isWorking: Bool
    let saveFailed: Bool
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        NotificationPromptLayout(
            systemImage: "sparkles",
            title: "Öğrenci fırsatları",
            identifier: "notifications.consent"
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Kampüsüne yakın indirimler, öğrenciye özel kampanyalar ve Premium fırsatları.")
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                NotificationBenefitRow(systemImage: "moon.zzz.fill", text: "Gece 22:00–09:00 arası asla.")
                NotificationBenefitRow(systemImage: "gearshape.fill", text: "İstediğin an Hesap'tan kapat.")
                if saveFailed {
                    Label(
                        "Tercihin kaydedilemedi. Bağlantını kontrol edip tekrar dene.",
                        systemImage: "exclamationmark.circle.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("notifications.consent.error")
                }
            }
        } actions: {
            NotificationPrimaryButton(
                title: "Evet, fırsatları bildir",
                isWorking: isWorking,
                identifier: "notifications.consent.accept",
                action: onAccept
            )
            Button(action: onDecline) {
                Text("Hayır, teşekkürler")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isWorking)
            .accessibilityIdentifier("notifications.consent.decline")
        }
    }
}

#if DEBUG
#Preview("Adım 2/2") {
    Color(.systemBackground)
        .sheet(isPresented: .constant(true)) {
            NotificationConsentView(isWorking: false, saveFailed: false, onAccept: {}, onDecline: {})
        }
}

#Preview("Adım 2/2 · kayıt hatası") {
    Color(.systemBackground)
        .sheet(isPresented: .constant(true)) {
            NotificationConsentView(isWorking: false, saveFailed: true, onAccept: {}, onDecline: {})
        }
}
#endif

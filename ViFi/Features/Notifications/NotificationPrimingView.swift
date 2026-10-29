import SwiftUI

/// Step 1/2 of the notification permission flow: why notifications are worth allowing, with "Bildirimleri Aç"
/// (the system prompt) and "Şimdi Değil". Only the first button asks the system, so the single system prompt is
/// not spent on someone who is not ready. Shown after the onboarding tour, and once more after a submission
/// (`source == .reask`) for someone who said no; when the system will not ask again, the primary button
/// opens the Settings app instead.
struct NotificationPrimingView: View {
    let source: NotificationPromptSource
    let needsSettingsApp: Bool
    let isWorking: Bool
    let onEnable: () -> Void
    let onOpenSettings: () -> Void
    let onDismiss: () -> Void

    private var isReask: Bool { source == .reask }

    var body: some View {
        NotificationPromptLayout(
            systemImage: "bell.badge.fill",
            title: isReask ? "Onaylanınca haber verelim mi?" : "Hiçbir şeyi kaçırma",
            identifier: "notifications.priming"
        ) {
            VStack(alignment: .leading, spacing: 16) {
                NotificationBenefitRow(systemImage: "books.vertical.fill", text: "Bölümüne yeni sınav gelince ilk sen haberdar ol")
                NotificationBenefitRow(
                    systemImage: "bitcoinsign.circle.fill",
                    text: "Gönderdiğin sınav onaylanınca coin'in yüklendiğini gör"
                )
                NotificationBenefitRow(systemImage: "megaphone.fill", text: "Önemli duyurular")
                if needsSettingsApp {
                    Text("Bildirimler şu an kapalı. Ayarlar'dan açabilirsin.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("notifications.priming.deniedNote")
                }
            }
        } actions: {
            if needsSettingsApp {
                NotificationPrimaryButton(
                    title: "Ayarlar'ı Aç",
                    isWorking: false,
                    identifier: "notifications.priming.openSettings",
                    action: onOpenSettings
                )
            } else {
                NotificationPrimaryButton(
                    title: "Bildirimleri Aç",
                    isWorking: isWorking,
                    identifier: "notifications.priming.enable",
                    action: onEnable
                )
            }
            Button("Şimdi Değil", action: onDismiss)
                .disabled(isWorking)
                .accessibilityIdentifier("notifications.priming.dismiss")
        }
    }
}

// MARK: - Shared pieces

/// The layout both permission steps share: an icon and title over a scrolling message, with the buttons pinned
/// at the bottom (so they stay in reach at large text sizes and in a half-height sheet).
struct NotificationPromptLayout<Message: View, Actions: View>: View {
    let systemImage: String
    let title: LocalizedStringKey
    let identifier: String
    @ViewBuilder let message: () -> Message
    @ViewBuilder let actions: () -> Actions

    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 64

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                IconBadge(systemName: systemImage, size: min(iconSize, 88))
                Text(title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                message()
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                actions()
            }
            .frame(maxWidth: 440)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(.bar)
        }
        .background(Color(.systemGroupedBackground))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

/// An icon with a line of text, for the benefit lists.
struct NotificationBenefitRow: View {
    let systemImage: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            Text(text)
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The full-width brand-orange button of a permission step. Black text on the orange: white would fall below
/// 3:1 contrast.
struct NotificationPrimaryButton: View {
    let title: LocalizedStringKey
    let isWorking: Bool
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isWorking {
                    ProgressView()
                        .tint(.black)
                }
                Text(title)
                    .font(.headline)
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isWorking)
        .accessibilityIdentifier(identifier)
    }
}

#if DEBUG
#Preview("Adım 1/2") {
    Color(.systemBackground)
        .sheet(isPresented: .constant(true)) {
            NotificationPrimingView(
                source: .prompt,
                needsSettingsApp: false,
                isWorking: false,
                onEnable: {},
                onOpenSettings: {},
                onDismiss: {}
            )
            .presentationDetents([.medium, .large])
        }
}

#Preview("Adım 1/2 · tekrar, kapalı") {
    Color(.systemBackground)
        .sheet(isPresented: .constant(true)) {
            NotificationPrimingView(
                source: .reask,
                needsSettingsApp: true,
                isWorking: false,
                onEnable: {},
                onOpenSettings: {},
                onDismiss: {}
            )
            .presentationDetents([.medium, .large])
        }
}
#endif

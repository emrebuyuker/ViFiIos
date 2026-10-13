import SwiftUI

/// A one-time pre-permission screen explaining why notifications help, shown once after the user has a profile.
/// Only "Bildirimleri Aç" triggers the system prompt, so the (single) system permission is not wasted on a
/// user who taps "Şimdi Değil".
struct NotificationPrimingView: View {
    let onEnable: () -> Void
    let onDismiss: () -> Void

    @ScaledMetric(relativeTo: .largeTitle) private var iconSize: CGFloat = 72

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            IconBadge(systemName: "bell.badge.fill", size: min(iconSize, 96))

            VStack(spacing: 12) {
                Text("Bildirimlere izin ver")
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Yeni sınavlar eklendiğinde ve önemli duyurularda haberdar ol.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                Button(action: onEnable) {
                    // Black on the brand orange: white text would fall below 3:1 contrast.
                    Text("Bildirimleri Aç")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("notifications.priming.enable")

                Button("Şimdi Değil", action: onDismiss)
                    .accessibilityIdentifier("notifications.priming.dismiss")
            }
            .frame(maxWidth: 440)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .presentationDetents([.medium])
        .accessibilityIdentifier("notifications.priming")
    }
}

/// Remembers that the pre-permission screen has been offered, so it is shown only once per device.
enum NotificationPrimingDefaults {
    private static let key = "notifications.primingOffered.v1"

    static func hasOffered(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func markOffered(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }
}

#if DEBUG
#Preview("Bildirim izni") {
    Color(.systemBackground)
        .sheet(isPresented: .constant(true)) {
            NotificationPrimingView(onEnable: {}, onDismiss: {})
        }
}
#endif

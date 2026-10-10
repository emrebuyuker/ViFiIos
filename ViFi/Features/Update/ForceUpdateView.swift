import SwiftUI

/// The blocking screen shown when the installed version is below the required minimum.
///
/// It fills the screen and cannot be dismissed: the only way forward is to update. `RootView` renders it in
/// place of the rest of the UI (not as a modal), so nothing behind it stays interactive. The gate lifts on
/// its own when the live policy no longer requires an update (e.g. after the user updates and relaunches).
struct ForceUpdateView: View {
    let update: AppUpdate

    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .largeTitle) private var logoSize: CGFloat = 84

    private var message: String {
        update.message ?? "Uygulamayı kullanmaya devam etmek için en son sürüme güncellemen gerekiyor."
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            VStack(spacing: 20) {
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: clampedLogoSize, height: clampedLogoSize)
                    .clipShape(.rect(cornerRadius: clampedLogoSize * 0.225, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                    .accessibilityHidden(true)

                VStack(spacing: 10) {
                    Text("Güncelleme Gerekli")
                        .font(.largeTitle.bold())
                        .accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("forceUpdate.title")
                    Text(message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button(action: openStore) {
                // Black on the brand orange: white text would fall below 3:1 contrast.
                Text("Güncelle")
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: 440)
            .accessibilityIdentifier("forceUpdate.update")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }

    private var clampedLogoSize: CGFloat {
        min(logoSize, 120)
    }

    private func openStore() {
        openURL(update.storeURL)
    }
}

#if DEBUG
#Preview("Zorunlu güncelleme") {
    ForceUpdateView(
        update: AppUpdate(
            version: "3.1.0",
            storeURL: URL(string: "https://apps.apple.com") ?? URL(filePath: "/"),
            message: nil
        )
    )
}
#endif

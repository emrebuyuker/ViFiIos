import SwiftUI
import UIKit

/// Account › Bildirim Ayarları: whether the OS allows notifications (with the way to turn them on) and the
/// "Kampanya ve fırsat bildirimleri" switch, the in-app opt-out Apple 4.5.4 requires. The switch is bound live to
/// the consent record; it is off until the user turns it on.
struct NotificationSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        NotificationSettingsScreen(
            notifications: environment.notifications,
            settings: environment.notificationSettings,
            analytics: environment.analytics
        )
    }
}

/// The Account list's entry to the screen: a row in a section of its own.
struct NotificationSettingsEntrySection: View {
    let isDisabled: Bool

    var body: some View {
        Section {
            NavigationLink {
                NotificationSettingsView()
            } label: {
                HStack(spacing: 14) {
                    IconBadge(systemName: "bell.badge.fill")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bildirim Ayarları")
                            .font(.headline)
                        Text("Bildirim izni ve kampanya tercihin")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .disabled(isDisabled)
            .accessibilityIdentifier("account.notificationSettings")
        }
    }
}

/// The screen itself, owning the view model for its lifetime.
private struct NotificationSettingsScreen: View {
    @State private var viewModel: NotificationSettingsViewModel
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppEnvironment.self) private var environment

    init(notifications: any NotificationServicing, settings: NotificationSettingsStore, analytics: any AnalyticsTracking) {
        _viewModel = State(initialValue: NotificationSettingsViewModel(
            notifications: notifications, settings: settings, analytics: analytics
        ))
    }

    var body: some View {
        List {
            permissionSection
            campaignSection

            if let message = viewModel.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("notificationSettings.error")
                }
            }
        }
        .accessibilityIdentifier("notificationSettings.list")
        .navigationTitle("Bildirim Ayarları")
        .navigationBarTitleDisplayMode(.inline)
        .animation(.smooth, value: viewModel.permission)
        .animation(.smooth, value: viewModel.errorMessage)
        .task { await viewModel.refreshPermission() }
        // Coming back from the Settings app, the permission may have changed.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await viewModel.refreshPermission() }
            }
        }
        .onAppear { environment.analytics.track(.screenView(name: "NotificationSettings")) }
    }

    // MARK: - Sections

    private var permissionSection: some View {
        Section {
            HStack(spacing: 14) {
                IconBadge(systemName: "bell.badge.fill")
                Text("Bildirim izni")
                    .font(.headline)
                Spacer()
                Text(viewModel.permissionTitle)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("notificationSettings.permission")

            if viewModel.canRequestPermission {
                Button("Bildirimleri Aç") {
                    Task { await viewModel.enableNotifications() }
                }
                .disabled(viewModel.isRequestingPermission)
                .accessibilityIdentifier("notificationSettings.enable")
            } else if viewModel.needsSettingsApp {
                Button("Ayarlar'ı Aç") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        openURL(url)
                    }
                }
                .accessibilityIdentifier("notificationSettings.openSettings")
            }
        } footer: {
            if let note = viewModel.permissionNote {
                Text(note)
            }
        }
    }

    private var campaignSection: some View {
        Section {
            Toggle(isOn: marketingBinding) {
                Text("Kampanya ve fırsat bildirimleri")
            }
            .disabled(!viewModel.isConsentAvailable || viewModel.isSavingConsent)
            .accessibilityIdentifier("notificationSettings.marketing")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("""
                    Kampüsüne yakın indirimler, öğrenciye özel kampanyalar ve Premium fırsatları. Gece 22:00–09:00 \
                    arası bildirim göndermeyiz. Kapalıyken kampanyaları ne bildirim olarak ne de Bildirimler \
                    sayfasında görürsün.
                    """)
                if viewModel.isConsentUnavailable {
                    Text("Tercihin şu an okunamıyor. Bağlantını kontrol edip bu sayfayı tekrar aç.")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("notificationSettings.unavailable")
                }
            }
        }
    }

    /// The switch shows the stored answer and writes a change through the view model.
    private var marketingBinding: Binding<Bool> {
        Binding(
            get: { viewModel.marketingEnabled },
            set: { enabled in Task { await viewModel.setMarketing(enabled) } }
        )
    }
}

#if DEBUG
#Preview("Bildirim ayarları") {
    NavigationStack {
        NotificationSettingsView()
    }
    .environment(AppEnvironment.mock())
}
#endif

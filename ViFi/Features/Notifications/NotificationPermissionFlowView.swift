import SwiftUI
import UIKit

/// The notification permission flow as a sheet: step 1/2 (the permission), then step 2/2 (the campaign consent)
/// as its next page. A stand-alone consent offer starts on step 2/2.
struct NotificationPermissionFlowView: View {
    let prompt: NotificationPrompt

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        NotificationPermissionFlowScreen(model: environment.notificationPrompts.makeFlow(for: prompt))
    }
}

/// The screen itself, owning the flow model for the lifetime of the sheet.
private struct NotificationPermissionFlowScreen: View {
    @State private var model: NotificationPermissionFlowModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    init(model: NotificationPermissionFlowModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        Group {
            switch model.page {
            case .permission:
                NotificationPrimingView(
                    source: model.prompt.source,
                    needsSettingsApp: model.needsSettingsApp,
                    isWorking: model.isWorking,
                    onEnable: { Task { await model.enableNotifications() } },
                    onOpenSettings: openSettings,
                    onDismiss: { model.declineNotifications() }
                )
            case .consent:
                NotificationConsentView(
                    isWorking: model.isWorking,
                    saveFailed: model.saveFailed,
                    onAccept: { Task { await model.answerConsent(true) } },
                    onDecline: { Task { await model.answerConsent(false) } }
                )
            }
        }
        .animation(.smooth, value: model.page)
        .presentationDetents([.medium, .large])
        // The consent is answered, not swiped away; after a failed save the sheet may be closed.
        .interactiveDismissDisabled(model.page == .consent && !model.saveFailed)
        .presentationDragIndicator(model.page == .consent && !model.saveFailed ? .hidden : .visible)
        .onAppear { model.start() }
        .onChange(of: model.isFinished) { _, isFinished in
            if isFinished {
                dismiss()
            }
        }
        .onDisappear { model.sheetDidClose() }
    }

    private func openSettings() {
        model.settingsWereOpened()
        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
            openURL(url)
        }
    }
}

#if DEBUG
#Preview("Bildirim izni akışı") {
    Color(.systemBackground)
        .sheet(isPresented: .constant(true)) {
            NotificationPermissionFlowView(
                prompt: NotificationPrompt(kind: .permission, source: .prompt, permission: .provisional)
            )
        }
        .environment(AppEnvironment.mock())
}
#endif

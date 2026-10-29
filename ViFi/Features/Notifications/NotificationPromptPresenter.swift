import SwiftUI

extension View {
    /// Presents the notification permission flow queued by `NotificationPromptCoordinator`, once no other modal
    /// is in the way. Applied once, on the archive in `RootView`, next to the inbox's presentation.
    func presentsNotificationPrompts() -> some View {
        modifier(NotificationPromptPresenter())
    }

    /// Offers the one re-ask of the campaign consent over the inbox it is applied to, when it is due. The inbox
    /// is a sheet itself, and a sheet cannot come from `RootView` over another one, so the inbox presents it.
    func offersMarketingConsentReask() -> some View {
        modifier(ConsentReaskPresenter())
    }
}

private struct NotificationPromptPresenter: ViewModifier {
    @Environment(AppEnvironment.self) private var environment

    func body(content: Content) -> some View {
        @Bindable var prompts = environment.notificationPrompts
        content
            .sheet(item: $prompts.presented) { prompt in
                NotificationPermissionFlowView(prompt: prompt)
            }
            // Keyed on the queued offer, so a newer one replaces a waiting one.
            .task(id: prompts.pending) { await presentWhenFree() }
    }

    /// Waits for the sheet, cover or alert in the way (the onboarding tour, an exam sheet that just closed) to be
    /// gone, then puts the queued offer on screen.
    private func presentWhenFree() async {
        let prompts = environment.notificationPrompts
        guard prompts.pending != nil else { return }
        while ModalPresentation.isShowing {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, prompts.pending != nil else { return }
        }
        prompts.present()
    }
}

private struct ConsentReaskPresenter: ViewModifier {
    @Environment(AppEnvironment.self) private var environment
    @State private var prompt: NotificationPrompt?

    func body(content: Content) -> some View {
        content
            .task { await offerIfDue() }
            .sheet(item: $prompt) { prompt in
                NotificationPermissionFlowView(prompt: prompt)
            }
    }

    private func offerIfDue() async {
        // Let the inbox show first; and leave someone who tapped a push to read that notification undisturbed.
        try? await Task.sleep(for: .milliseconds(700))
        guard !Task.isCancelled, prompt == nil, environment.notificationRouter.highlightedId == nil else { return }
        prompt = await environment.notificationPrompts.inboxConsentReask()
    }
}

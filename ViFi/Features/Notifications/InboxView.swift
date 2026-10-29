import SwiftUI

/// The in-app notification box: the public announcements and the user's own notifications, newest first.
/// Opening it marks what is there as read. A notification may carry one action (a button, and the card itself is
/// tappable): open an exam, the premium screen, the add-exam flow or a link. A tapped push opens the inbox on its
/// notification, which is scrolled to and highlighted (`NotificationRouter`).
struct InboxView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isShowingPaywall = false
    @State private var isShowingAddExam = false

    var body: some View {
        NavigationStack {
            content
                .accessibilityIdentifier("inbox.list")
                .navigationTitle("Bildirimler")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Bitti") { dismiss() }
                            .accessibilityIdentifier("inbox.done")
                    }
                }
                .onAppear {
                    environment.analytics.track(.screenView(name: "Inbox"))
                    environment.inbox.markAllRead()
                }
                // Entries that arrive while the inbox is open (or that were still loading when it opened) are seen
                // right away too, so they do not leave the bell lit once it is closed.
                .onChange(of: environment.inbox.unreadCount) { _, count in
                    if count > 0 {
                        environment.inbox.markAllRead()
                    }
                }
                .sheet(isPresented: $isShowingPaywall) {
                    PaywallView()
                }
                .sheet(isPresented: $isShowingAddExam) {
                    AddExamView()
                        .presentationDragIndicator(.visible)
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch environment.inbox.state {
        case .loading:
            LoadingStateView()
        case let .failed(message):
            ErrorStateView(message: message) { environment.inbox.retry() }
        case let .loaded(items):
            if items.isEmpty, !environment.inbox.hasPartialFailure {
                EmptyStateView(
                    title: "Bildirim yok",
                    systemImage: "bell",
                    message: "Yeni bildirimler burada görünecek."
                )
            } else {
                list(of: items)
            }
        }
    }

    private func list(of items: [InboxItem]) -> some View {
        // The notification a tapped push is about, once it is among the entries (it may still be loading).
        let highlightedId = environment.notificationRouter.highlightedId.flatMap { id in
            items.contains { $0.id == id } ? id : nil
        }
        return ScrollViewReader { proxy in
            List {
                if environment.inbox.hasPartialFailure {
                    partialFailureRow
                }
                ForEach(items) { item in
                    InboxRow(
                        item: item,
                        isUnread: environment.inbox.isUnread(item),
                        isHighlighted: item.id == highlightedId,
                        button: button(for: item.action),
                        onAction: { perform(item.action) }
                    )
                    .id(item.id)
                }
            }
            .listStyle(.insetGrouped)
            .onChange(of: highlightedId, initial: true) { _, id in
                if let id {
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    /// Shown above the entries when only one of the two sources could be read.
    private var partialFailureRow: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Label("Bazı bildirimler yüklenemedi.", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Tekrar Dene") { environment.inbox.retry() }
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("inbox.retry")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("inbox.partialFailure")
        }
    }

    // MARK: - Actions

    /// The button for `action`, or `nil` when there is nothing to offer: no action, a place (Phase 2), or the
    /// premium screen for someone who is already subscribed.
    private func button(for action: NotificationAction?) -> InboxActionButton? {
        guard let action else { return nil }
        if case .paywall = action, environment.subscription.isSubscribed { return nil }
        return action.inboxButton
    }

    /// Does what the notification's action says (the button and a tap on the card both end up here).
    private func perform(_ action: NotificationAction?) {
        guard let action, button(for: action) != nil else { return }
        switch action {
        case let .exam(target):
            // The exam opens on the archive's navigation stack, behind this sheet: close the sheet first.
            dismiss()
            router.openExam(at: target.path, kind: target.kind)
        case .paywall:
            isShowingPaywall = true
        case .addExam:
            isShowingAddExam = true
        case let .url(url):
            openURL(url)
        case .location:
            break
        }
    }
}

// MARK: - Action button

/// How a notification's action is offered in the inbox.
nonisolated struct InboxActionButton: Equatable {
    let title: String
    let systemImage: String
}

extension NotificationAction {
    /// The label and symbol of the action's button; `nil` for an action the app does not offer yet (`location`
    /// arrives with the maps work, NOTIFICATIONS.md phase 2).
    var inboxButton: InboxActionButton? {
        switch self {
        case .exam: InboxActionButton(title: String(localized: "Sınava Git"), systemImage: "doc.text.magnifyingglass")
        case .paywall: InboxActionButton(title: String(localized: "Premium'a Göz At"), systemImage: "star.fill")
        case .addExam: InboxActionButton(title: String(localized: "Sınav Ekle"), systemImage: "plus.rectangle.on.rectangle")
        case .url: InboxActionButton(title: String(localized: "Bağlantıyı Aç"), systemImage: "safari")
        case .location: nil
        }
    }
}

extension NotificationKind {
    /// The symbol on the entry's icon badge.
    var inboxSymbol: String {
        switch self {
        case .general: "megaphone.fill"
        case .promo: "tag.fill"
        case .system: "bell.badge.fill"
        }
    }
}

// MARK: - Row

private struct InboxRow: View {
    let item: InboxItem
    let isUnread: Bool
    let isHighlighted: Bool
    let button: InboxActionButton?
    let onAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            card
            if let button {
                Button(action: onAction) {
                    // Black on the brand orange: white text would fall below 3:1 contrast.
                    Label(button.title, systemImage: button.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("inbox.row.\(item.id).action")
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(isHighlighted ? Color.accentColor.opacity(0.18) : nil)
    }

    /// The text of the notification; tapping it does what the action says, like the button.
    @ViewBuilder
    private var card: some View {
        if button != nil {
            cardContent
                .contentShape(Rectangle())
                .onTapGesture(perform: onAction)
                .accessibilityAddTraits(.isButton)
        } else {
            cardContent
        }
    }

    private var cardContent: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(systemName: item.kind.inboxSymbol, size: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.headline)
                if !item.body.isEmpty {
                    Text(item.body)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                caption
            }

            Spacer(minLength: 0)

            if isUnread {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Okunmadı")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("inbox.row.\(item.id)")
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    private var caption: some View {
        HStack(spacing: 6) {
            // Campaigns are labelled as such (App Store guideline 4.5.4).
            if item.kind == .promo {
                Text("Kampanya")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if let date = item.createdAt {
                Text(date, format: .dateTime.day().month().year())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

#if DEBUG
#Preview("Bildirimler") {
    InboxView()
        .environment(AppEnvironment.mock())
        .environment(Router())
}
#endif

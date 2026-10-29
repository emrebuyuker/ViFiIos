import SwiftUI

/// The admin's notification history: what was sent, scheduled or sent automatically, with delivery numbers, and a
/// way to cancel a scheduled one. Reached from the composer's toolbar.
struct NotificationHistoryView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        NotificationHistoryScreen(service: environment.notificationAdmin)
            .onAppear { environment.analytics.track(.screenView(name: "NotificationHistory")) }
    }
}

private struct NotificationHistoryScreen: View {
    @State private var viewModel: NotificationHistoryViewModel

    init(service: any NotificationAdminServicing) {
        _viewModel = State(initialValue: NotificationHistoryViewModel(service: service))
    }

    var body: some View {
        content
            .navigationTitle("Gönderim Geçmişi")
            .navigationBarTitleDisplayMode(.inline)
            .animation(.smooth, value: viewModel.state)
            .task { await viewModel.loadIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.state {
        case .loading:
            LoadingStateView(title: "Geçmiş yükleniyor…")
        case let .failed(message):
            ErrorStateView(message: message) { Task { await viewModel.refresh() } }
        case let .loaded(notifications):
            if notifications.isEmpty {
                EmptyStateView(
                    title: "Henüz bildirim yok",
                    systemImage: "bell.slash",
                    message: "Gönderdiğin ve zamanladığın bildirimler burada görünür."
                )
            } else {
                list(of: notifications)
            }
        }
    }

    private func list(of notifications: [SentNotification]) -> some View {
        List {
            if let message = viewModel.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("notificationComposer.history.error")
                }
            }
            Section {
                ForEach(notifications) { notification in
                    NotificationHistoryRow(notification: notification)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if notification.status == .scheduled {
                                cancelButton(for: notification)
                            }
                        }
                        .contextMenu {
                            if notification.status == .scheduled {
                                cancelButton(for: notification)
                            }
                        }
                }
            }
        }
        .accessibilityIdentifier("notificationComposer.history.list")
        .refreshable { await viewModel.refresh() }
    }

    private func cancelButton(for notification: SentNotification) -> some View {
        Button("İptal et", systemImage: "xmark.circle", role: .destructive) {
            Task { await viewModel.cancel(notification) }
        }
        .disabled(viewModel.cancelingId != nil)
        .accessibilityIdentifier("notificationComposer.history.row.\(notification.id).cancel")
    }
}

/// One history entry: title, audience, status and badges, and the delivery numbers once it has gone out.
private struct NotificationHistoryRow: View {
    let notification: SentNotification

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            IconBadge(systemName: notification.kind.adminSymbol)
            VStack(alignment: .leading, spacing: 5) {
                Text(notification.title)
                    .font(.headline)
                if !notification.audienceLabel.isEmpty {
                    Text(notification.audienceLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                badges
                if let timeLine {
                    Text(timeLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if hasDelivered {
                    statsLines
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("notificationComposer.history.row.\(notification.id)")
    }

    private var badges: some View {
        // Wraps instead of squeezing at large Dynamic Type sizes.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { badgeViews }
            VStack(alignment: .leading, spacing: 4) { badgeViews }
        }
    }

    @ViewBuilder
    private var badgeViews: some View {
        HistoryBadge(text: notification.status.adminLabel, tint: notification.status.adminTint)
        HistoryBadge(text: notification.kind.adminLabel, tint: .secondary)
        if notification.isTest {
            HistoryBadge(text: String(localized: "Test"), tint: .purple)
        }
        if notification.isAutomatic {
            HistoryBadge(text: String(localized: "Otomatik"), tint: .teal)
        }
    }

    /// Pushes and opens only mean something once the notification has gone out.
    private var hasDelivered: Bool {
        switch notification.status {
        case .sent, .sending, .failed: true
        case .scheduled, .canceled: false
        }
    }

    private var statsLines: some View {
        let stats = notification.stats
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(stats.recipients) alıcı · \(stats.pushSent) push gönderildi · \(stats.pushFailed) başarısız")
            Text("\(stats.opened) kişi açtı · \(stats.actionTapped) kişi butona dokundu")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    /// When it goes out (scheduled) or went out, with a note when quiet hours moved it.
    private var timeLine: String? {
        switch notification.status {
        case .scheduled:
            guard let date = notification.scheduledAt else { return nil }
            let time = date.formatted(date: .abbreviated, time: .shortened)
            return notification.deferredByQuietHours
                ? String(localized: "\(time) için zamanlandı (sessiz saat)")
                : String(localized: "\(time) için zamanlandı")
        case .sent, .sending, .failed:
            return (notification.sentAt ?? notification.createdAt)?.formatted(date: .abbreviated, time: .shortened)
        case .canceled:
            return notification.createdAt?.formatted(date: .abbreviated, time: .shortened)
        }
    }
}

/// A small status pill. Primary text on a tinted capsule keeps the contrast in both appearances.
private struct HistoryBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.22), in: .capsule)
            .fixedSize()
    }
}

#if DEBUG
#Preview("Gönderim Geçmişi") {
    NavigationStack {
        NotificationHistoryView()
    }
    .environment(AppEnvironment.mock())
    .environment(Router())
}
#endif

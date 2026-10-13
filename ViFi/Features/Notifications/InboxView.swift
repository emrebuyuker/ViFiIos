import SwiftUI

/// The in-app notification box: the public announcements, newest first. Opening it marks the current ones read.
struct InboxView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

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
                    environment.announcements.markAllRead()
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        let announcements = environment.announcements.announcements
        if announcements.isEmpty {
            EmptyStateView(
                title: "Bildirim yok",
                systemImage: "bell",
                message: "Yeni duyurular burada görünecek."
            )
        } else {
            List(announcements) { announcement in
                InboxRow(
                    announcement: announcement,
                    isUnread: !environment.announcements.readIds.contains(announcement.id)
                )
                .accessibilityIdentifier("inbox.row.\(announcement.id)")
            }
            .listStyle(.insetGrouped)
        }
    }
}

private struct InboxRow: View {
    let announcement: Announcement
    let isUnread: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconBadge(systemName: "bell.fill", size: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(announcement.title)
                    .font(.headline)
                if !announcement.body.isEmpty {
                    Text(announcement.body)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let date = announcement.createdAt {
                    Text(date, format: .dateTime.day().month().year())
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 0)

            if isUnread {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Okunmadı")
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Bildirimler") {
    InboxView()
        .environment(AppEnvironment.mock())
}
#endif

import SwiftUI

/// An SF Symbol on a soft rounded square, used as the leading icon of rows and cards.
struct IconBadge: View {
    let systemName: String
    var tint: Color = .accentColor
    var size: CGFloat = 40

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.15), in: .rect(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Full-screen loading indicator.
struct LoadingStateView: View {
    var title: LocalizedStringKey = "Yükleniyor…"

    var body: some View {
        ProgressView {
            Text(title)
                .foregroundStyle(.secondary)
        }
        .controlSize(.large)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("state.loading")
    }
}

/// Full-screen error with a retry action.
struct ErrorStateView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Bir sorun oluştu", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            // Black on the brand orange: white text would fall below 3:1 contrast.
            Button(action: retry) {
                Text("Tekrar Dene")
                    .foregroundStyle(.black)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("state.retry")
        }
        .accessibilityIdentifier("state.error")
    }
}

/// Full-screen empty state.
struct EmptyStateView: View {
    let title: LocalizedStringKey
    let systemImage: String
    var message: LocalizedStringKey?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message {
                Text(message)
            }
        }
        .accessibilityIdentifier("state.empty")
    }
}

#Preview("States") {
    TabView {
        LoadingStateView()
            .tabItem { Text("Loading") }
        ErrorStateView(message: ArchiveError.offline.userMessage) {}
            .tabItem { Text("Error") }
        EmptyStateView(title: "Kayıt bulunamadı", systemImage: "tray")
            .tabItem { Text("Empty") }
    }
}

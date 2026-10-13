import SwiftUI

/// The first-launch onboarding tour: a short, skippable paged introduction to finding exams, unlocking the
/// locked ones with coins, and contributing exams to earn coins.
///
/// Presented as a full-screen cover over the archive on the first launch (see `RootView`), and replayable from
/// the About screen. `onFinish` is called when the user taps "Başla" on the last page or "Atla" at any point;
/// the caller decides what that means (mark the tour seen, or just dismiss a replay).
struct OnboardingView: View {
    let onFinish: () -> Void
    /// Where the tour was opened from, recorded with the completion event ("first_launch" | "replay").
    var source: String = "first_launch"

    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        OnboardingScreen(
            pages: OnboardingPage.tour,
            analytics: environment.analytics,
            source: source,
            onFinish: onFinish
        )
    }
}

/// A single page of the tour.
private struct OnboardingPage: Identifiable {
    let id: Int
    let systemImage: String
    let tint: Color
    let title: String
    let message: String

    /// The four tour pages, in order.
    static let tour: [OnboardingPage] = [
        OnboardingPage(
            id: 0,
            systemImage: "graduationcap.fill",
            tint: .accentColor,
            title: "ViFi'ye hoş geldin",
            message: "Üniversitelerin geçmiş sınavları tek bir yerde. Uygulamanın nasıl çalıştığına hızlıca bakalım."
        ),
        OnboardingPage(
            id: 1,
            systemImage: "books.vertical.fill",
            tint: .accentColor,
            title: "Sınavları bul",
            message: "Üniversite, fakülte, bölüm ve ders seç; sınavları görsel ya da PDF olarak uygulama içinde görüntüle."
        ),
        OnboardingPage(
            id: 2,
            systemImage: "lock.fill",
            tint: .orange,
            title: "Kilitli sınavları aç",
            message: "Her derste en eski iki sınav ücretsizdir. Diğerleri kilitlidir ve 100 coin ile kalıcı olarak açılır."
        ),
        OnboardingPage(
            id: 3,
            systemImage: "plus.circle.fill",
            tint: .orange,
            title: "Soru ekle, coin kazan",
            message: "Kendi sınavlarını ekle; gönderdiğin sınavlar onaylandığında coin'lerin hesabına yüklenir."
        ),
    ]
}

private struct OnboardingScreen: View {
    let pages: [OnboardingPage]
    let analytics: any AnalyticsTracking
    let source: String
    let onFinish: () -> Void

    @State private var selection = 0

    private var isLastPage: Bool { selection >= pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            skipBar

            TabView(selection: $selection) {
                ForEach(pages) { page in
                    OnboardingPageView(page: page)
                        .tag(page.id)
                        .accessibilityIdentifier("onboarding.page.\(page.id)")
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .accessibilityIdentifier("onboarding.pager")

            primaryButton
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .onAppear { analytics.track(.screenView(name: "Onboarding")) }
    }

    private var skipBar: some View {
        HStack {
            Spacer()
            if !isLastPage {
                Button("Atla") { finish(method: "skipped") }
                    .font(.body.weight(.semibold))
                    .accessibilityIdentifier("onboarding.skip")
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
    }

    private var primaryButton: some View {
        Button(action: advance) {
            // Black on the brand orange: white text would fall below 3:1 contrast.
            Text(isLastPage ? "Başla" : "İleri")
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .frame(maxWidth: 440)
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
        .accessibilityIdentifier(isLastPage ? "onboarding.start" : "onboarding.next")
    }

    private func advance() {
        if isLastPage {
            finish(method: "finished")
        } else {
            withAnimation { selection += 1 }
        }
    }

    private func finish(method: String) {
        analytics.track(.onboardingCompleted(method: method, source: source))
        onFinish()
    }
}

private struct OnboardingPageView: View {
    let page: OnboardingPage

    @ScaledMetric(relativeTo: .largeTitle) private var heroSize: CGFloat = 96

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)

            IconBadge(systemName: page.systemImage, tint: page.tint, size: min(heroSize, 140))

            VStack(spacing: 12) {
                Text(page.title)
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(page.message)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Onboarding") {
    OnboardingView(onFinish: {})
        .environment(AppEnvironment.mock())
}
#endif

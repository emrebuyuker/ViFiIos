import Foundation
@testable import ViFi

/// Shared fixtures for the composer's view model suites.
@MainActor
struct NotificationComposerFixture {
    let clock = TestClock()

    static let facets = AudienceFacets(total: 20, universities: [
        node("zonguldak", "Zonguldak Üniversitesi", 5, 2, 3),
        node("sakarya", "Sakarya Üniversitesi", 12, 7, 5, children: [
            node("muhendislik", "Mühendislik Fakültesi", 9, 5, 4, children: [
                node("makine", "Makine Mühendisliği", 6, 4, 2),
                node("bilgisayar", "Bilgisayar Mühendisliği", 3, 1, 2),
            ]),
            node("iibf", "İktisadi ve İdari Bilimler Fakültesi", 3, 2, 1),
        ]),
        node("ankara", "Ankara Üniversitesi", 3, 1, 2),
    ])

    private static func node(
        _ id: String,
        _ name: String,
        _ total: Int,
        _ female: Int,
        _ male: Int,
        children: [AudienceNode] = []
    ) -> AudienceNode {
        AudienceNode(id: id, name: name, counts: AudienceCounts(total: total, female: female, male: male), children: children)
    }

    func makeViewModel(
        service: StubNotificationAdminService = StubNotificationAdminService()
    ) -> (NotificationComposerViewModel, StubNotificationAdminService) {
        service.facetsResult = .success(Self.facets)
        return (NotificationComposerViewModel(service: service, now: clock.now), service)
    }

    /// A form that is ready to send to everyone.
    func readyViewModel(
        service: StubNotificationAdminService = StubNotificationAdminService()
    ) -> (NotificationComposerViewModel, StubNotificationAdminService) {
        let (viewModel, service) = makeViewModel(service: service)
        viewModel.title = "Başlık"
        viewModel.body = "Mesaj"
        return (viewModel, service)
    }
}

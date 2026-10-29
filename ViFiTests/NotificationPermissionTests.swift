import Testing
import UserNotifications
@testable import ViFi

@Suite("NotificationPermission")
struct NotificationPermissionTests {
    @Test("Every system status maps to its permission", arguments: [
        (UNAuthorizationStatus.notDetermined, NotificationPermission.notDetermined),
        (.denied, .denied),
        (.provisional, .provisional),
        (.authorized, .authorized),
        (.ephemeral, .authorized),
    ])
    func mapsStatus(status: UNAuthorizationStatus, expected: NotificationPermission) {
        #expect(NotificationPermission(status) == expected)
    }

    @Test("Only authorized and provisional deliver notifications")
    func deliversNotifications() {
        #expect(NotificationPermission.authorized.deliversNotifications)
        #expect(NotificationPermission.provisional.deliversNotifications)
        #expect(!NotificationPermission.notDetermined.deliversNotifications)
        #expect(!NotificationPermission.denied.deliversNotifications)
    }
}

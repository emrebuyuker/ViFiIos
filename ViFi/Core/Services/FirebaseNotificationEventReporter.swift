@preconcurrency import FirebaseFunctions
import Foundation

/// Reports notification events through the `trackNotificationEvent` Cloud Function (`europe-west1`), which counts
/// each event once per user. Callers treat a failure as non-fatal (see `NotificationEventTracker`).
final class FirebaseNotificationEventReporter: NotificationEventReporting {
    private static let region = "europe-west1"
    private static let name = "trackNotificationEvent"

    private let functions: Functions

    init(functions: Functions = Functions.functions(region: region)) {
        self.functions = functions
    }

    func report(_ event: NotificationEvent, notificationId: String) async throws {
        _ = try await functions.httpsCallable(Self.name).call([
            "notificationId": notificationId,
            "event": event.rawValue,
        ])
    }
}

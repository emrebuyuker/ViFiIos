import Foundation
import os

/// Keeps this device's push registration in step with the signed-in user (NOTIFICATIONS.md §3.5).
///
/// Two things must meet before a registration is written: the FCM token (handed over by `AppDelegate` whenever
/// Messaging produces or refreshes it) and the signed-in user (reported by `RootView`). Whichever arrives last
/// triggers the write, so a token that came before sign-in is registered the moment the user signs in, and a
/// refreshed token follows the user. Registering is best-effort — a failure is logged and retried at the next
/// trigger (token refresh, next sign-in or launch), never surfaced.
///
/// Signing out or deleting the account calls `unregister(uid:)` first, while the user can still write. That wait
/// is bounded: with no connection the delete would otherwise never be acknowledged, and a flaky network must
/// never keep someone from signing out. (A device that is left behind is cleaned up by the server once its token
/// stops working, or when the same token is registered under another account.)
final class DeviceRegistrationStore {
    /// A token registered under a user.
    private struct Registration: Equatable {
        let token: String
        let userId: String
    }

    /// The latest FCM token Messaging handed over, if any.
    private(set) var token: String?
    /// The signed-in user this device is registered under, once a sign-in was reported.
    private(set) var userId: String?

    private let registrar: any DeviceRegistering
    private let unregisterTimeout: Duration
    /// The registration the server acknowledged.
    private var registered: Registration?
    /// A registration being written.
    private var inFlight: Registration?

    /// - Parameter unregisterTimeout: How long signing out waits for the server to acknowledge the removal.
    init(registrar: any DeviceRegistering, unregisterTimeout: Duration = .seconds(3)) {
        self.registrar = registrar
        self.unregisterTimeout = unregisterTimeout
    }

    /// Messaging produced or refreshed the FCM token. Registers it when a user is signed in.
    func tokenDidChange(_ token: String?) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.token = trimmed?.isEmpty == false ? trimmed : nil
        registerIfNeeded()
    }

    /// A user is signed in (or changed). Registers the current token under them when there is one.
    func userDidSignIn(uid: String) {
        if userId != uid {
            registered = nil
            inFlight = nil
        }
        userId = uid
        registerIfNeeded()
    }

    /// The user signed out; nothing is registered for the next one until they sign in.
    func userDidSignOut() {
        userId = nil
        registered = nil
        inFlight = nil
    }

    /// Removes this device from `uid` before sign-out or account deletion, waiting at most `unregisterTimeout`.
    /// Never throws: a failure or timeout is logged and the caller carries on.
    func unregister(uid: String) async {
        // Stop registering first, so a token refresh while the delete is in flight cannot bring the device back.
        userDidSignOut()

        let registrar = registrar
        let outcome = FirstOutcome<Bool>()
        let removal = Task {
            do {
                try await registrar.unregister(uid: uid)
                outcome.resolve(.success(true))
            } catch {
                outcome.resolve(.failure(error))
            }
        }
        let timer = Task { [unregisterTimeout] in
            try await Task.sleep(for: unregisterTimeout)
            outcome.resolve(.success(false))
        }
        defer { timer.cancel() }

        do {
            let completed = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
                    outcome.attach(continuation)
                }
            } onCancel: {
                outcome.resolve(.failure(CancellationError()))
                removal.cancel()
            }
            if !completed {
                Logger.app.notice("Removing the device registration timed out; continuing")
            }
        } catch {
            let reason = String(describing: error)
            Logger.app.notice("Removing the device registration failed: \(reason, privacy: .public)")
        }
    }

    // MARK: - Private

    private func registerIfNeeded() {
        guard let token, let userId else { return }
        let registration = Registration(token: token, userId: userId)
        guard registration != registered, registration != inFlight else { return }
        inFlight = registration
        Task {
            do {
                try await registrar.register(token: token, uid: userId)
                if inFlight == registration {
                    registered = registration
                    inFlight = nil
                }
            } catch {
                let reason = String(describing: error)
                Logger.app.notice("Registering the device failed: \(reason, privacy: .public)")
                if inFlight == registration {
                    inFlight = nil
                }
            }
        }
    }
}

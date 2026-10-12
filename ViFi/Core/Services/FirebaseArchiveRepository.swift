@preconcurrency import FirebaseDatabase
import Foundation
import os

/// Reads the exam archive from the Firebase Realtime Database.
///
/// The `Universitiess` tree is persisted on disk and kept in sync, so every list the user has opened
/// (and, after the first full sync, the whole archive) stays available offline.
///
/// Reading requires a signed-in user. Keep-synced is therefore armed lazily, the first time the archive is
/// used while signed in, and re-armed after every sign-out: the server cancels a listener the rules reject,
/// and the database never restarts it on its own.
///
/// Snapshots are delivered on a background queue and parsed there into `Sendable` models: reading a
/// node materialises its whole subtree, which must not happen on the main actor.
final class FirebaseArchiveRepository: ArchiveRepository {
    private static let rootKey = "Universitiess"

    /// The shared database, configured once by `ViFiDatabase` before its first reference is created.
    private static var database: Database { ViFiDatabase.shared }

    private let root: DatabaseReference
    private let timeout: Duration
    private let auth: any AuthServicing
    /// Whether keep-synced is armed for the current sign-in.
    private var isKeepSyncedArmed = false
    private var sessionTask: Task<Void, Never>?
    /// The live `archiveChanges()` consumers; one shared root observer fans each change out to all of them.
    private var changeContinuations: [UUID: AsyncStream<Void>.Continuation] = [:]
    /// The single `.value` observer on the root, installed with the first consumer and removed with the last.
    private var rootObserverHandle: DatabaseHandle?

    /// - Parameters:
    ///   - auth: The sign-in state; the archive is only kept in sync while a user is signed in.
    ///   - timeout: How long a read may wait for data before failing with `ArchiveError.offline`.
    init(auth: any AuthServicing, timeout: Duration = .seconds(15)) {
        self.auth = auth
        self.timeout = timeout
        root = Self.database.reference(withPath: Self.rootKey)
        sessionTask = Task { [weak self, auth] in
            for await user in auth.userChanges() where user == nil {
                self?.disarmKeepSynced()
            }
        }
    }

    deinit {
        sessionTask?.cancel()
        // The shared root observer is removed when its last consumer's stream ends (`endChangeStream`) or the
        // server cancels it (`finishAllStreams`); this app-lifetime repository is never actually deinitialised.
    }

    func items(at path: ArchivePath) async throws -> [ArchiveItem] {
        armKeepSyncedIfNeeded()
        // An empty archive is just an empty list; a missing child means the path no longer exists.
        let allowsMissingNode = path.isRoot
        return try await readNode(at: path) { snapshot in
            guard snapshot.exists() || allowsMissingNode else { throw ArchiveError.notFound }
            return ArchiveParser.items(in: snapshot.value, at: path)
        }
    }

    func document(at path: ArchivePath) async throws -> ExamDocument {
        armKeepSyncedIfNeeded()
        return try await readNode(at: path) { snapshot in
            guard let document = ArchiveParser.document(in: snapshot.value, at: path) else {
                throw ArchiveError.notFound
            }
            return document
        }
    }

    /// With persistence on, the first read after launch is answered from the previous session's disk
    /// cache before the server sync lands. A live listener on the root fires again once fresh data
    /// arrives (and on every later edit), so visible lists can re-read.
    ///
    /// Every consumer shares one root `.value` observer: with N screens open on the navigation stack, a single
    /// change is materialised and dispatched once, not N times.
    func archiveChanges() -> AsyncStream<Void> {
        armKeepSyncedIfNeeded()
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        changeContinuations[id] = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { @MainActor in self?.endChangeStream(id) }
        }
        installRootObserverIfNeeded()
        return stream
    }
}

// MARK: - Change broadcasting

private extension FirebaseArchiveRepository {
    /// Attaches the one root observer, the first time a consumer subscribes.
    func installRootObserverIfNeeded() {
        guard rootObserverHandle == nil else { return }
        // `DatabaseReference` is thread-safe but not annotated `Sendable`.
        nonisolated(unsafe) let root = root
        rootObserverHandle = root.observe(
            .value,
            with: { @Sendable [weak self] _ in
                Task { @MainActor in self?.broadcastChange() }
            },
            withCancel: { @Sendable [weak self] _ in
                Task { @MainActor in self?.finishAllStreams() }
            }
        )
    }

    /// Notifies every live consumer of a change.
    func broadcastChange() {
        for continuation in changeContinuations.values {
            continuation.yield()
        }
    }

    /// Drops one consumer; removes the shared observer once the last one goes away.
    func endChangeStream(_ id: UUID) {
        changeContinuations[id] = nil
        if changeContinuations.isEmpty {
            removeRootObserver()
        }
    }

    /// Ends every consumer's stream when the server cancels the listener (signed out, revoked token).
    func finishAllStreams() {
        let continuations = Array(changeContinuations.values)
        changeContinuations.removeAll()
        removeRootObserver()
        for continuation in continuations {
            continuation.finish()
        }
    }

    func removeRootObserver() {
        guard let rootObserverHandle else { return }
        root.removeObserver(withHandle: rootObserverHandle)
        self.rootObserverHandle = nil
    }
}

// MARK: - Keep-synced

private extension FirebaseArchiveRepository {
    /// Keeps the archive synced for the signed-in user, once per sign-in.
    ///
    /// When the server rejects a kept-synced listener (signed out, revoked token), the database drops the
    /// listener but still remembers the location as kept-synced, so `keepSynced(true)` alone would be a no-op.
    /// Clearing it first re-registers exactly one listener; both calls run in order on the database queue,
    /// and the database never registers the same location twice.
    func armKeepSyncedIfNeeded() {
        guard !isKeepSyncedArmed, auth.currentUser != nil else { return }
        isKeepSyncedArmed = true
        root.keepSynced(false)
        root.keepSynced(true)
    }

    /// Stops syncing on sign-out; the next use after signing in arms it again.
    func disarmKeepSynced() {
        guard isKeepSyncedArmed else { return }
        isKeepSyncedArmed = false
        root.keepSynced(false)
    }
}

// MARK: - Reading

private extension FirebaseArchiveRepository {
    /// Reads the node at `path` once and parses it inside the Firebase callback, so the non-sendable
    /// `DataSnapshot` never leaves it.
    ///
    /// The read races the timeout and task cancellation; whichever finishes first resumes the caller.
    func readNode<Value: Sendable>(
        at path: ArchivePath,
        parse: @escaping @Sendable (DataSnapshot) throws -> Value
    ) async throws -> Value {
        let reference = path.components.reduce(root) { $0.child($1) }
        let outcome = FirstOutcome<Value>()

        let timeoutTask = Task { [timeout] in
            try await Task.sleep(for: timeout)
            outcome.resolve(.failure(ArchiveError.offline))
        }
        defer { timeoutTask.cancel() }

        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    outcome.attach(continuation)
                    reference.observeSingleEvent(
                        of: .value,
                        with: { @Sendable snapshot in
                            outcome.resolve(Result { try parse(snapshot) })
                        },
                        withCancel: { @Sendable error in
                            outcome.resolve(.failure(Self.archiveError(fromCancellation: error)))
                        }
                    )
                }
            } onCancel: {
                outcome.resolve(.failure(CancellationError()))
            }
        } catch {
            if !(error is CancellationError) {
                let location = ([Self.rootKey] + path.components).joined(separator: "/")
                let reason = String(describing: error)
                Logger.archive.error("Reading \(location, privacy: .public) failed: \(reason, privacy: .public)")
            }
            throw error
        }
    }

    /// Firebase reports a rejected read with this domain and code (`permission_denied`).
    nonisolated static let firebaseErrorDomain = "com.firebase"
    nonisolated static let permissionDeniedCode = 1

    /// Maps the error a listener is cancelled with to an `ArchiveError`.
    nonisolated static func archiveError(fromCancellation error: any Error) -> ArchiveError {
        let error = error as NSError
        let isPermissionDenied = (error.domain == firebaseErrorDomain && error.code == permissionDeniedCode)
            || error.localizedDescription.localizedCaseInsensitiveContains("permission")
        return isPermissionDenied ? .permissionDenied : .unknown(message: error.localizedDescription)
    }
}

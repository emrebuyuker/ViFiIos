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

    /// The default database, configured once before its first use.
    ///
    /// Firebase only accepts these settings before the first reference is created, so they are applied
    /// in a lazily initialised static, which Swift runs exactly once per process.
    private static let database: Database = {
        let database = Database.database()
        database.isPersistenceEnabled = true
        // Synced data is never evicted; the headroom keeps recently browsed nodes around as well.
        database.persistenceCacheSizeBytes = 50 * 1024 * 1024
        database.callbackQueue = DispatchQueue(label: "com.BuyukerYazilim.ViFi.database", qos: .userInitiated)
        return database
    }()

    private let root: DatabaseReference
    private let timeout: Duration
    private let auth: any AuthServicing
    /// Whether keep-synced is armed for the current sign-in.
    private var isKeepSyncedArmed = false
    private var sessionTask: Task<Void, Never>?

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
    func archiveChanges() -> AsyncStream<Void> {
        armKeepSyncedIfNeeded()
        // `DatabaseReference` is thread-safe but not annotated `Sendable`.
        nonisolated(unsafe) let root = root
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let handle = root.observe(
                .value,
                with: { @Sendable _ in continuation.yield() },
                withCancel: { @Sendable _ in continuation.finish() }
            )
            continuation.onTermination = { @Sendable _ in
                root.removeObserver(withHandle: handle)
            }
        }
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

// MARK: - FirstOutcome

/// A one-shot continuation that several racing sources (database callback, timeout, cancellation)
/// may try to resume: the first result wins and later ones are ignored.
private nonisolated final class FirstOutcome<Value: Sendable>: Sendable {
    private enum State: Sendable {
        case pending
        case waiting(CheckedContinuation<Value, any Error>)
        /// Resolved before the continuation was attached (e.g. the task was already cancelled).
        case resolved(Result<Value, any Error>)
        case finished
    }

    private let state = OSAllocatedUnfairLock(initialState: State.pending)

    func attach(_ continuation: CheckedContinuation<Value, any Error>) {
        let earlyResult: Result<Value, any Error>? = state.withLock { state in
            guard case let .resolved(result) = state else {
                state = .waiting(continuation)
                return nil
            }
            state = .finished
            return result
        }
        if let earlyResult {
            continuation.resume(with: earlyResult)
        }
    }

    func resolve(_ result: Result<Value, any Error>) {
        let continuation: CheckedContinuation<Value, any Error>? = state.withLock { state in
            switch state {
            case .pending:
                state = .resolved(result)
                return nil
            case let .waiting(continuation):
                state = .finished
                return continuation
            case .resolved, .finished:
                return nil
            }
        }
        continuation?.resume(with: result)
    }
}

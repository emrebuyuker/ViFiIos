import Foundation
import os

/// A one-shot continuation that several racing sources (a database callback, a timeout, task cancellation)
/// may try to resume: the first result wins and later ones are ignored.
///
/// Used to bound Firebase callback reads with a timeout and honour task cancellation, without ever
/// resuming a `CheckedContinuation` twice.
nonisolated final class FirstOutcome<Value: Sendable>: Sendable {
    private enum State: Sendable {
        case pending
        case waiting(CheckedContinuation<Value, any Error>)
        /// Resolved before the continuation was attached (e.g. the task was already cancelled).
        case resolved(Result<Value, any Error>)
        case finished
    }

    private let state = OSAllocatedUnfairLock(initialState: State.pending)

    init() {}

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

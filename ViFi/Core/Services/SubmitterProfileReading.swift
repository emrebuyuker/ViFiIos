@preconcurrency import FirebaseDatabase
import Foundation
import os

/// Who submitted an exam, as shown to the admin reviewing it. Deliberately minimal: no phone number (KVKK) and
/// no gender; only what a moderator needs to recognise the submitter.
nonisolated struct SubmitterInfo: Sendable, Equatable {
    let fullName: String
    let university: String
    let faculty: String
    let department: String
}

/// Reads the display-only profile of a submission's owner (admin-only; the rules let an admin read any profile).
protocol SubmitterProfileReading: Sendable {
    /// The submitter's info, or `nil` when the profile is missing (for example a deleted account).
    func submitter(uid: String) async throws -> SubmitterInfo?
}

/// Maps a raw `users/<uid>/profile` value to a `SubmitterInfo`, dropping every field the moderator must not see.
nonisolated enum SubmitterInfoParser {
    static func info(from value: Any?) -> SubmitterInfo? {
        guard let entries = value as? [String: Any],
              let name = string(entries["name"]),
              let surname = string(entries["surname"]) else {
            return nil
        }
        return SubmitterInfo(
            fullName: "\(name) \(surname)",
            university: string(entries["university"]) ?? "",
            faculty: string(entries["faculty"]) ?? "",
            department: string(entries["department"]) ?? ""
        )
    }

    private static func string(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}

/// Live reader over the Realtime Database `users/<uid>/profile` node; the snapshot is parsed inside the callback.
final class FirebaseSubmitterProfileReader: SubmitterProfileReading {
    private let timeout: Duration

    init(timeout: Duration = .seconds(15)) {
        self.timeout = timeout
    }

    func submitter(uid: String) async throws -> SubmitterInfo? {
        let reference = ViFiDatabase.shared.reference(withPath: "users").child(uid).child("profile")
        let outcome = FirstOutcome<SubmitterInfo?>()
        let timeoutTask = Task { [timeout] in
            try await Task.sleep(for: timeout)
            outcome.resolve(.failure(ProfileError.offline))
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SubmitterInfo?, any Error>) in
                outcome.attach(continuation)
                reference.observeSingleEvent(
                    of: .value,
                    with: { @Sendable snapshot in
                        outcome.resolve(.success(SubmitterInfoParser.info(from: snapshot.value)))
                    },
                    withCancel: { @Sendable error in
                        outcome.resolve(.failure(FirebaseProfileService.profileError(fromCancellation: error)))
                    }
                )
            }
        } onCancel: {
            outcome.resolve(.failure(CancellationError()))
        }
    }
}

/// Used where no reader is wired: every submitter is reported as unknown.
struct NoopSubmitterProfileReader: SubmitterProfileReading {
    func submitter(uid: String) async throws -> SubmitterInfo? { nil }
}

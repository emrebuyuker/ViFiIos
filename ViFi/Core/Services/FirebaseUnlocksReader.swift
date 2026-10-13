@preconcurrency import FirebaseFirestore
import Foundation

/// Reads the user's unlocked exams from Cloud Firestore `users/<uid>/unlocks` (each document's id is an exam
/// id). The documents are written only by the unlock Cloud Function; the owner may read them.
final class FirebaseUnlocksReader: UnlocksReading {
    private let firestore: Firestore

    init(firestore: Firestore = ViFiFirestore.shared) {
        self.firestore = firestore
    }

    func unlockedExamIds(uid: String) async throws -> Set<String> {
        let snapshot = try await firestore
            .collection("users").document(uid).collection("unlocks")
            .getDocuments()
        return Set(snapshot.documents.map(\.documentID))
    }
}

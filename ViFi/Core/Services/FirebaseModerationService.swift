@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseStorage
import Foundation
import os

/// Admin moderation backed by Cloud Firestore and Cloud Storage, with no Cloud Function: the admin's device
/// resolves the submission against the archive, copies its files into the public archive storage, and commits
/// the catalog nodes, the exam document, the coin credit and the status change in one atomic batch.
///
/// The coin credit uses `FieldValue.increment`, so it is race-free; approving is guarded by a re-read of the
/// submission's `pending` status and by the ledger entry (keyed by submission id) already existing, so a
/// double tap or a second admin cannot double-credit.
final class FirebaseModerationService: ModerationServicing {
    private static let submissions = "submissions"
    private static let catalogNodes = "catalogNodes"
    private static let exams = "exams"
    private static let wallets = "wallets"
    private static let ledger = "ledger"

    private let firestore: Firestore
    private let storage: Storage
    private let resolver: SubmissionTierResolver
    private let rewards: any RewardsConfigReading

    init(
        repository: any ArchiveRepository,
        rewards: any RewardsConfigReading,
        firestore: Firestore = ViFiFirestore.shared,
        storage: Storage = ViFiStorage.shared
    ) {
        self.firestore = firestore
        self.storage = storage
        resolver = SubmissionTierResolver(repository: repository)
        self.rewards = rewards
    }

    func pendingSubmissions() async throws -> [ExamSubmissionRecord] {
        do {
            let snapshot = try await firestore.collection(Self.submissions)
                .whereField("status", isEqualTo: "pending")
                .getDocuments()
            return snapshot.documents
                .compactMap { document in
                    let data = document.data()
                    let createdAt = (data["createdAt"] as? Timestamp)?.dateValue()
                    return SubmissionRecordParser.record(id: document.documentID, data: data, createdAt: createdAt)
                }
                .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        } catch {
            throw Self.moderationError(from: error)
        }
    }

    func approve(_ record: ExamSubmissionRecord) async throws -> ApprovalResult {
        guard record.status == "pending" else { throw ModerationError.notPending }

        let placement = try await resolver.placement(of: record.location)
        let coins = max(0, await currentRewards()?.coins(for: placement.tier) ?? 0)
        let plan = ArchivePublishPlan.make(record: record, placement: placement)

        // Copy the files into the public archive storage only when a new exam is actually published.
        let publishedFiles = plan.examId == nil ? [] : try await copyFiles(record)

        try await ensureStillCreditable(record, coins: coins)
        try await commit(record, placement: placement, plan: plan, coins: coins, files: publishedFiles)

        return ApprovalResult(tier: placement.tier, coins: coins, publishedExamId: plan.examId)
    }

    func reject(_ record: ExamSubmissionRecord, reason: String?) async throws {
        guard record.status == "pending" else { throw ModerationError.notPending }
        var data: [String: Any] = ["status": "rejected", "reviewedAt": FieldValue.serverTimestamp()]
        if let reason, !reason.isEmpty {
            data["rejectionReason"] = String(reason.prefix(ExamSubmission.maxTextLength))
        }
        do {
            try await firestore.collection(Self.submissions).document(record.id).updateData(data)
        } catch {
            throw Self.moderationError(from: error)
        }
    }

    func deleteExam(at path: ArchivePath) async throws {
        guard let examId = path.components.last, let courseId = path.parent?.components.last else {
            throw ModerationError.unknown(message: String(localized: "Silinecek sınav bulunamadı."))
        }
        do {
            // Read the file paths first, so the orphaned Storage objects can be cleaned up after the delete.
            let examRef = firestore.collection(Self.exams).document(examId)
            let snapshot = try await examRef.getDocument()
            let files = snapshot.data()?["files"] as? [[String: Any]] ?? []
            let storagePaths = files.compactMap { $0["storagePath"] as? String }

            // Remove the exam and decrement its course's exam count atomically.
            let batch = firestore.batch()
            batch.deleteDocument(examRef)
            batch.updateData(
                ["childCount": FieldValue.increment(Int64(-1))],
                forDocument: firestore.collection(Self.catalogNodes).document(courseId)
            )
            try await batch.commit()

            // Best-effort: the archive no longer references these files; a failure just leaves an orphan.
            for storagePath in storagePaths {
                try? await storage.reference(withPath: storagePath).delete()
            }
        } catch {
            throw Self.moderationError(from: error)
        }
    }

    // MARK: - Private

    /// The current reward config, read from the first value of the live stream.
    private func currentRewards() async -> RewardsConfig? {
        for await config in rewards.rewardsChanges() {
            return config
        }
        return nil
    }

    /// Re-checks right before committing that the submission is still pending, and (when crediting) that no
    /// ledger entry exists yet, so a stale list or a second admin cannot double-credit.
    private func ensureStillCreditable(_ record: ExamSubmissionRecord, coins: Int) async throws {
        do {
            let submission = try await firestore.collection(Self.submissions).document(record.id).getDocument()
            guard (submission.data()?["status"] as? String) == "pending" else { throw ModerationError.notPending }
            if coins > 0 {
                let entry = try await ledgerReference(ownerId: record.ownerId, id: record.id).getDocument()
                guard !entry.exists else { throw ModerationError.alreadyCredited }
            }
        } catch let error as ModerationError {
            throw error
        } catch {
            throw Self.moderationError(from: error)
        }
    }

    /// Downloads each pending file and re-uploads it under `imagess/` or `pdfs/` with fresh, server-set
    /// metadata, returning the published references in reading order.
    private func copyFiles(_ record: ExamSubmissionRecord) async throws -> [SubmissionFileRef] {
        let folder = record.kind == .images ? "imagess" : "pdfs"
        let maxBytes = Int64(ExamSubmission.maxFileBytes)
        var published: [SubmissionFileRef] = []
        do {
            for file in record.files.sorted(by: { $0.order < $1.order }) {
                let data = try await storage.reference(withPath: file.storagePath).data(maxSize: maxBytes)
                let destination = "\(folder)/\(UUID().uuidString).\(record.kind.fileExtension)"
                let metadata = StorageMetadata()
                metadata.contentType = record.kind.uploadContentType
                _ = try await storage.reference(withPath: destination).putDataAsync(data, metadata: metadata)
                published.append(SubmissionFileRef(storagePath: destination, order: file.order))
            }
        } catch {
            throw Self.moderationError(from: error)
        }
        return published
    }

    /// Commits the whole approval atomically: catalog nodes, child-count bumps, the exam document, the coin
    /// credit (balance + ledger) and the submission status change.
    private func commit(
        _ record: ExamSubmissionRecord,
        placement: ResolvedPlacement,
        plan: ArchivePublishPlan,
        coins: Int,
        files: [SubmissionFileRef]
    ) async throws {
        let batch = firestore.batch()
        let catalog = firestore.collection(Self.catalogNodes)

        for node in plan.nodesToCreate {
            batch.setData(node.fields, forDocument: catalog.document(node.id))
        }
        for id in plan.childCountIncrements {
            batch.updateData(["childCount": FieldValue.increment(Int64(1))], forDocument: catalog.document(id))
        }
        if let examId = plan.examId {
            batch.setData(
                plan.examDocument(record: record, files: files),
                forDocument: firestore.collection(Self.exams).document(examId)
            )
        }
        if coins > 0 {
            let walletRef = firestore.collection(Self.wallets).document(record.ownerId)
            batch.setData(
                ["balance": FieldValue.increment(Int64(coins)), "updatedAt": FieldValue.serverTimestamp()],
                forDocument: walletRef,
                merge: true
            )
            batch.setData([
                "type": "earn",
                "amount": coins,
                "submissionId": record.id,
                "tier": placement.tier.rawValue,
                "createdAt": FieldValue.serverTimestamp(),
            ], forDocument: walletRef.collection(Self.ledger).document(record.id))
        }

        var submissionData: [String: Any] = [
            "status": "approved",
            "tier": placement.tier.rawValue,
            "coins": coins,
            "reviewedAt": FieldValue.serverTimestamp(),
        ]
        if let examId = plan.examId {
            submissionData["publishedExamId"] = examId
        }
        batch.updateData(submissionData, forDocument: firestore.collection(Self.submissions).document(record.id))

        do {
            try await batch.commit()
        } catch {
            throw Self.moderationError(from: error)
        }
    }

    private func ledgerReference(ownerId: String, id: String) -> DocumentReference {
        firestore.collection(Self.wallets).document(ownerId).collection(Self.ledger).document(id)
    }

    nonisolated static func moderationError(from error: any Error) -> any Error {
        if error is ModerationError || error is CancellationError {
            return error
        }
        let nsError = error as NSError
        if nsError.domain == FirestoreErrorDomain, let code = FirestoreErrorCode.Code(rawValue: nsError.code) {
            switch code {
            case .permissionDenied:
                return ModerationError.permissionDenied
            case .unavailable, .deadlineExceeded:
                return ModerationError.offline
            default:
                break
            }
        }
        if nsError.domain == NSURLErrorDomain {
            return ModerationError.offline
        }
        Logger.app.error("Moderation operation failed: \(String(describing: error), privacy: .public)")
        return ModerationError.unknown(message: error.localizedDescription)
    }
}

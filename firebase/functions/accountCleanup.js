// Server-side cleanup of a deleted account (NOTIFICATIONS.md §8 phase 3/H; user decision 2026-10-30), run by the
// Firebase Auth user-deletion trigger. It honours what the public pages promise — `hosting/hesap-silme.html` and
// `hosting/gizlilik.html`:
//
// Deleted ("Hemen silinir" / "En geç 30 gün içinde silinir"):
// - Firestore `users/{uid}` with every subcollection: unlocked exams ("açılan sınav kayıtları"), notification
//   inbox, registered devices, notification settings.
// - `wallets/{uid}` with its `ledger` ("Coin bakiyesi").
// - `subscriptions/{uid}` (entitlement state keyed by the account).
// - The user's still-pending submissions ("Onay bekleyen sınav gönderimleri") and every file under
//   `pending/{uid}/` in Storage — the archive never points there: an approval copies the files to `imagess/`/`pdfs/`.
// - The Realtime Database profile `users/{uid}` ("Profil … Hemen silinir"). The app deletes it before deleting the
//   account; this also covers an account deleted from the console (the e-mail request path) or a failed client delete.
// - The legacy Realtime Database queue `pendingExams/{uid}` (submissions made before the Firestore move; no longer
//   written, but old entries may still hold this user's uploads' metadata). User decision 2026-10-30.
//
// Kept:
// - Published archive content (exams, catalog nodes, their files): "Arşive eklenmiş sınavlar … arşivde kalır".
// - `purchasedTransactions/{transactionId}` — "Satın alma kayıtları (sipariş/işlem kimliği) aynı satın almanın tekrar
//   kullanılmasını önlemek için saklanır; hesabınla bağı … kaldırılır": the record stays (so the purchase still
//   cannot be replayed) but its `uid` is removed.
// - Reviewed (approved / rejected) submission records are not touched (the pages promise nothing about them).
//
// Every step is idempotent and runs even when another fails; a failure is rethrown at the end so the trigger is
// retried, and the retry simply redoes what is left.

import { FieldValue } from 'firebase-admin/firestore';
import * as logger from 'firebase-functions/logger';

/**
 * A Firebase uid usable as a single path segment in Firestore, Storage and the Realtime Database. Phone Auth uids
 * are 28 alphanumerics; anything with a separator could address another user's data, so it is refused.
 */
const UID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;
const FAILED_PRECONDITION = 9;

/**
 * Deletes (or unlinks) everything the account `uid` left behind.
 *
 * @param {{ db: import('firebase-admin/firestore').Firestore, rtdb: import('firebase-admin/database').Database,
 *   bucket: { deleteFiles: (query: { prefix: string }) => Promise<void> } }} deps
 * @param {string} uid The deleted account.
 * @returns {Promise<{ uid: string, pendingSubmissions: number, unlinkedPurchases: number } | { skipped: string }>}
 */
export async function deleteAccountData(deps, uid) {
  if (typeof uid !== 'string' || !UID_PATTERN.test(uid)) {
    logger.error('Account cleanup refused an unsupported uid', { uid: String(uid).slice(0, 140) });
    return { skipped: 'unsupported-uid' };
  }
  const { db, rtdb, bucket } = deps;

  const steps = {
    // `recursiveDelete` also removes subcollections under a document that has no fields of its own.
    firestoreUser: () => db.recursiveDelete(db.collection('users').doc(uid)),
    wallet: () => db.recursiveDelete(db.collection('wallets').doc(uid)),
    subscription: () => db.recursiveDelete(db.collection('subscriptions').doc(uid)),
    pendingSubmissions: () => deletePendingSubmissions(db, uid),
    // Pending submissions' uploads (and leftovers of rejected / failed ones); a missing prefix is a no-op.
    pendingFiles: () => bucket.deleteFiles({ prefix: `pending/${uid}/` }),
    profile: () => rtdb.ref('users').child(uid).remove(),
    legacyPendingExams: () => rtdb.ref('pendingExams').child(uid).remove(),
    unlinkedPurchases: () => unlinkPurchases(db, uid),
  };

  const names = Object.keys(steps);
  const results = await Promise.allSettled(names.map((name) => steps[name]()));
  const failures = [];
  const summary = { uid, pendingSubmissions: 0, unlinkedPurchases: 0 };
  results.forEach((result, index) => {
    const name = names[index];
    if (result.status === 'rejected') {
      failures.push({ step: name, error: result.reason });
      return;
    }
    if (name in summary) summary[name] = result.value;
  });

  if (failures.length > 0) {
    logger.error('Account cleanup incomplete; the trigger will retry', {
      uid,
      failed: failures.map(({ step, error }) => ({ step, error: error?.message ?? String(error) })),
    });
    throw new AggregateError(failures.map(({ error }) => error), `Account cleanup failed: ${failures.map(({ step }) => step).join(', ')}`);
  }
  logger.info('Account data deleted', summary);
  return summary;
}

/**
 * Deletes the account's submissions that are still `pending`. Each delete is conditional on the document being
 * unchanged since it was read, so a submission an admin approves at that very moment is not deleted; such a
 * conflict fails the step and the retry decides again.
 */
async function deletePendingSubmissions(db, uid) {
  // Equality on one field only: served by the automatic single-field index.
  const snapshot = await db.collection('submissions').where('ownerId', '==', uid).get();
  const pending = snapshot.docs.filter((doc) => doc.get('status') === 'pending');
  let deleted = 0;
  const conflicts = [];
  await Promise.all(pending.map(async (doc) => {
    try {
      await doc.ref.delete({ lastUpdateTime: doc.updateTime });
      deleted += 1;
    } catch (error) {
      // NOT_FOUND cannot happen with a lastUpdateTime precondition; a changed document reports FAILED_PRECONDITION.
      if (error?.code === FAILED_PRECONDITION) conflicts.push(doc.id);
      else throw error;
    }
  }));
  if (conflicts.length > 0) throw new Error(`Pending submissions changed during cleanup: ${conflicts.join(', ')}`);
  return deleted;
}

/**
 * Removes the account from its consumed purchase transactions (the replay guard keeps the document, so the same
 * store transaction can never unlock again, but no longer says whose it was).
 */
async function unlinkPurchases(db, uid) {
  const snapshot = await db.collection('purchasedTransactions').where('uid', '==', uid).get();
  if (snapshot.empty) return 0;
  const writer = db.bulkWriter();
  // Each write's own promise carries its failure (`close` does not reject); handled right away, rethrown below.
  const updates = snapshot.docs.map((doc) => writer
    .update(doc.ref, { uid: FieldValue.delete(), accountDeletedAt: FieldValue.serverTimestamp() })
    .then(() => null, (error) => error));
  await writer.close();
  const failure = (await Promise.all(updates)).find(Boolean);
  if (failure) throw failure;
  return snapshot.size;
}

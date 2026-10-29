// Records a paid single-exam unlock once its purchase has been verified with the store (App Store or Google Play).
// Shared by both platforms' branches of `purchaseExamUnlock`, so the replay protection is one and the same.

import { HttpsError } from 'firebase-functions/v2/https';
import { FieldValue } from 'firebase-admin/firestore';

/**
 * Writes `users/<uid>/unlocks/<examId>` and consumes the purchase's transaction id in one Firestore transaction. It is
 * idempotent and replay-safe: each transaction id can unlock exactly one exam, once.
 *
 * @param {import('firebase-admin/firestore').Firestore} db The named `vifi` database.
 * @param {{uid: string, examId: string, transactionId: string, store?: string}} purchase A verified purchase. `store`
 *   tags Google Play records (`google_play`); App Store records are written without it, exactly as before 4.0.0
 *   Android.
 * @returns {Promise<{alreadyUnlocked: boolean}>}
 */
export function recordPurchasedUnlock(db, { uid, examId, transactionId, store }) {
  const unlockRef = db.collection('users').doc(uid).collection('unlocks').doc(examId);
  // Binds the transaction id to the exam it unlocked, so the same purchase cannot be replayed for another exam.
  const transactionRef = db.collection('purchasedTransactions').doc(transactionId);
  const storeField = store ? { store } : {};

  return db.runTransaction(async (transaction) => {
    const transactionSnapshot = await transaction.get(transactionRef);
    const unlockSnapshot = await transaction.get(unlockRef);

    if (transactionSnapshot.exists) {
      // Already consumed. A retry for the same (uid, exam) is idempotent; anything else is a replay.
      if (transactionSnapshot.get('uid') === uid && transactionSnapshot.get('examId') === examId) {
        return { alreadyUnlocked: true };
      }
      throw new HttpsError('failed-precondition', 'Bu satın alma zaten kullanıldı.');
    }

    // The exam may already be unlocked (with coins, or an earlier purchase). Still consume this transaction id
    // so it cannot be reused, but do not rewrite the unlock.
    if (!unlockSnapshot.exists) {
      transaction.set(unlockRef, {
        examId,
        source: 'purchase',
        transactionId,
        ...storeField,
        createdAt: FieldValue.serverTimestamp(),
      });
    }
    transaction.set(transactionRef, {
      uid,
      examId,
      ...storeField,
      createdAt: FieldValue.serverTimestamp(),
    });

    return { alreadyUnlocked: unlockSnapshot.exists };
  });
}

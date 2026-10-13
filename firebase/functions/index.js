// ViFi Cloud Functions.
//
// Coin *spending* is the one operation that must run server-side: unlocking an exam debits the user's own
// wallet, and a client cannot be trusted to do that honestly (security rules cannot atomically verify "exactly
// N coins were taken AND the unlock was granted"). Crediting stays serverless because an admin — trusted —
// performs it; spending is done by ordinary users, so it lives here, behind the Admin SDK.
//
// `unlockExam` is a callable: it verifies the signed-in +90 user, then runs one Firestore transaction that
// checks the balance, debits the cost, writes the unlock and appends a spend ledger entry. It is idempotent —
// an already-unlocked exam is a no-op that charges nothing.

import { onCall, HttpsError } from 'firebase-functions/v2/https';
import { initializeApp } from 'firebase-admin/app';
import { getFirestore, FieldValue } from 'firebase-admin/firestore';

initializeApp();

// The archive, wallets, unlocks and ledger all live in the named `vifi` database (not `(default)`).
const db = getFirestore('vifi');

// Coins charged to unlock one exam. Keep in step with the client's `ExamLock.unlockCost`.
const UNLOCK_COST = 100;

// Co-located with the eur3 Firestore database to keep the transaction's round-trips short.
export const unlockExam = onCall({ region: 'europe-west1' }, async (request) => {
  const { auth, data } = request;
  const phoneNumber = auth?.token?.phone_number ?? '';
  if (!auth || !/^\+90[0-9]{10}$/.test(phoneNumber)) {
    throw new HttpsError('permission-denied', 'Bu işlem için giriş yapmış olman gerekiyor.');
  }

  const examId = typeof data?.examId === 'string' ? data.examId.trim() : '';
  if (!examId) {
    throw new HttpsError('invalid-argument', 'Sınav kimliği gerekli.');
  }

  const uid = auth.uid;
  const examSnapshot = await db.collection('exams').doc(examId).get();
  if (!examSnapshot.exists || examSnapshot.get('status') !== 'published') {
    throw new HttpsError('not-found', 'Sınav bulunamadı.');
  }

  const walletRef = db.collection('wallets').doc(uid);
  const unlockRef = db.collection('users').doc(uid).collection('unlocks').doc(examId);

  return db.runTransaction(async (transaction) => {
    // All reads first (Firestore transactions require reads before writes).
    const unlockSnapshot = await transaction.get(unlockRef);
    const walletSnapshot = await transaction.get(walletRef);
    const balance = Number(walletSnapshot.get('balance') ?? 0);

    // Already unlocked: idempotent, no charge.
    if (unlockSnapshot.exists) {
      return { alreadyUnlocked: true, balance };
    }

    if (balance < UNLOCK_COST) {
      throw new HttpsError('failed-precondition', 'Bu sınavı açmak için yeterli coin yok.');
    }

    const newBalance = balance - UNLOCK_COST;
    transaction.set(
      walletRef,
      { balance: newBalance, updatedAt: FieldValue.serverTimestamp() },
      { merge: true }
    );
    transaction.set(unlockRef, {
      examId,
      coinsSpent: UNLOCK_COST,
      createdAt: FieldValue.serverTimestamp(),
    });
    transaction.set(walletRef.collection('ledger').doc(), {
      type: 'spend',
      amount: -UNLOCK_COST,
      examId,
      createdAt: FieldValue.serverTimestamp(),
    });

    return { alreadyUnlocked: false, balance: newBalance };
  });
});

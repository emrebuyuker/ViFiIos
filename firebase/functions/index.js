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
import { defineSecret } from 'firebase-functions/params';
import { initializeApp } from 'firebase-admin/app';
import { getFirestore, FieldValue } from 'firebase-admin/firestore';
import { createHash } from 'node:crypto';
import { verifyExamUnlockTransaction } from './appStore.js';

initializeApp();

// The archive, wallets, unlocks and ledger all live in the named `vifi` database (not `(default)`).
const db = getFirestore('vifi');

// Salt for hashing phone numbers in login diagnostics. A phone number is low-entropy (10^10), so an unsalted hash
// is trivially reversible; this secret keeps the stored hashes from being turned back into numbers. Set it before
// deploying: `firebase functions:secrets:set LOGIN_DIAGNOSTIC_SALT`. Never committed to the (public) repo.
const DIAGNOSTIC_SALT = defineSecret('LOGIN_DIAGNOSTIC_SALT');

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

// Records a failed sign-in attempt for support diagnostics, so we can later look up why a specific number could
// not sign in (e.g. the backend's SMS anti-abuse "Error code: 39", or an App Check failure).
//
// App Check is deliberately NOT enforced: a sign-in that fails *because* App Check cannot be minted must still be
// recordable. Instead the server records whether a valid App Check token was present (`appCheckServer`), and the
// client sends its own on-device probe result (`appCheckClient`). The caller is unauthenticated (the sign-in just
// failed), so nothing here trusts `auth`; inputs are validated and clamped, and the collection is admin-read-only.
//
// Phone numbers are never stored raw — only a salted SHA-256 hash (for exact match via a tool) plus the last 4
// digits (for coarse console lookup). Records auto-expire after 60 days via the `expireAt` TTL field; enable the
// TTL policy on `loginDiagnostics.expireAt` in the console.
const DIAGNOSTIC_TTL_DAYS = 60;

function clampString(value, max) {
  return typeof value === 'string' && value.trim() ? value.trim().slice(0, max) : null;
}

export const recordLoginDiagnostic = onCall(
  { region: 'europe-west1', enforceAppCheck: false, secrets: [DIAGNOSTIC_SALT] },
  async (request) => {
    const data = request.data ?? {};

    const reason = clampString(data.reason, 64) ?? 'unknown';
    const step = data.step === 'send_code' || data.step === 'verify' ? data.step : 'unknown';

    const phoneNumber = typeof data.phoneNumber === 'string' ? data.phoneNumber.trim() : '';
    let numberHash = null;
    let last4 = null;
    if (/^\+90[0-9]{10}$/.test(phoneNumber)) {
      // Trim the salt so the hash is stable regardless of a trailing newline in the stored secret; the lookup
      // script (scripts/lookup-login-diagnostics.mjs) trims identically so its hash matches this one.
      numberHash = createHash('sha256').update(`${DIAGNOSTIC_SALT.value().trim()}:${phoneNumber}`).digest('hex');
      last4 = phoneNumber.slice(-4);
    }

    // Server-verified App Check result. With enforcement off, `request.app` is set only for a valid token; a
    // present-but-invalid token leaves it undefined, so the raw header distinguishes "invalid" from "absent".
    const sentAppCheck = request.rawRequest?.headers?.['x-firebase-appcheck'];
    const appCheckServer = request.app ? 'valid' : sentAppCheck ? 'invalid' : 'absent';

    await db.collection('loginDiagnostics').add({
      numberHash,
      last4,
      reason,
      step,
      backendCode: Number.isInteger(data.backendCode) ? data.backendCode : null,
      appCheckClient: clampString(data.appCheckStatus, 32),
      appCheckServer,
      appVersion: clampString(data.appVersion, 32),
      osVersion: clampString(data.osVersion, 32),
      deviceModel: clampString(data.deviceModel, 64),
      occurredAt: clampString(data.occurredAt, 40),
      createdAt: FieldValue.serverTimestamp(),
      expireAt: new Date(Date.now() + DIAGNOSTIC_TTL_DAYS * 24 * 60 * 60 * 1000),
    });

    return { ok: true };
  }
);

// `purchaseExamUnlock` unlocks a single exam paid for with money (the `exam.unlock` consumable) instead of
// coins. The client sends the purchase's signed StoreKit 2 transaction; we verify Apple's signature here (a
// client cannot be trusted to claim it paid), then record the unlock — no coins are touched. It is idempotent
// and replay-safe: each transaction id can unlock exactly one exam, once.
export const purchaseExamUnlock = onCall({ region: 'europe-west1' }, async (request) => {
  const { auth, data } = request;
  const phoneNumber = auth?.token?.phone_number ?? '';
  if (!auth || !/^\+90[0-9]{10}$/.test(phoneNumber)) {
    throw new HttpsError('permission-denied', 'Bu işlem için giriş yapmış olman gerekiyor.');
  }

  const examId = typeof data?.examId === 'string' ? data.examId.trim() : '';
  if (!examId) {
    throw new HttpsError('invalid-argument', 'Sınav kimliği gerekli.');
  }
  const signedTransaction = typeof data?.signedTransaction === 'string' ? data.signedTransaction : '';
  if (!signedTransaction) {
    throw new HttpsError('invalid-argument', 'Satın alma bilgisi gerekli.');
  }

  // Verify the purchase with Apple before granting anything.
  let transactionId;
  try {
    ({ transactionId } = await verifyExamUnlockTransaction(signedTransaction));
  } catch (error) {
    console.error('Exam unlock purchase verification failed:', error);
    throw new HttpsError('failed-precondition', 'Satın alma doğrulanamadı.');
  }

  const uid = auth.uid;
  const examSnapshot = await db.collection('exams').doc(examId).get();
  if (!examSnapshot.exists || examSnapshot.get('status') !== 'published') {
    throw new HttpsError('not-found', 'Sınav bulunamadı.');
  }

  const unlockRef = db.collection('users').doc(uid).collection('unlocks').doc(examId);
  // Binds the transaction id to the exam it unlocked, so the same purchase cannot be replayed for another exam.
  const transactionRef = db.collection('purchasedTransactions').doc(transactionId);

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
        createdAt: FieldValue.serverTimestamp(),
      });
    }
    transaction.set(transactionRef, {
      uid,
      examId,
      createdAt: FieldValue.serverTimestamp(),
    });

    return { alreadyUnlocked: unlockSnapshot.exists };
  });
});

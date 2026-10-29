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
//
// Targeted notifications (`getNotificationAudience`, `previewNotification`, `sendNotification`, `onDeviceWritten`)
// live in `notifications/`; this file only wires them to their triggers and live dependencies.

import { onCall, HttpsError } from 'firebase-functions/v2/https';
import { onDocumentWritten } from 'firebase-functions/v2/firestore';
import { defineSecret } from 'firebase-functions/params';
import { initializeApp } from 'firebase-admin/app';
import { getFirestore, FieldValue } from 'firebase-admin/firestore';
import { getDatabase } from 'firebase-admin/database';
import { getMessaging } from 'firebase-admin/messaging';
import { getStorage } from 'firebase-admin/storage';
import { createHash } from 'node:crypto';
import { verifyExamUnlockTransaction } from './appStore.js';
import { verifyExamUnlockPurchase } from './googlePlay.js';
import { recordPurchasedUnlock } from './purchaseUnlock.js';
import {
  getNotificationAudienceHandler,
  previewNotificationHandler,
  sendNotificationHandler,
} from './notifications/admin.js';
import { onDeviceWrittenHandler } from './notifications/devices.js';
import { SIGNED_IMAGE_URL_TTL_MS } from './notifications/schema.js';

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

// `purchaseExamUnlock` unlocks a single exam paid for with money (the exam-unlock consumable) instead of coins,
// on either platform:
// - iOS (no `platform`, or `'ios'`) sends the purchase's signed StoreKit 2 transaction; we verify Apple's signature.
// - Android (`platform: 'android'`) sends the Google Play purchase token; we look the purchase up with the Play
//   Developer API and check it was bought for this exam.
// A client cannot be trusted to claim it paid, so nothing is granted before the store confirms the purchase; then
// the unlock is recorded — no coins are touched. It is idempotent and replay-safe: each transaction id can unlock
// exactly one exam, once.
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

  // The iOS client predates the platform field and sends none.
  const platform = data?.platform ?? 'ios';
  let purchase;
  if (platform === 'ios') {
    purchase = await verifyAppStorePurchase(data);
  } else if (platform === 'android') {
    purchase = await verifyGooglePlayPurchase(data, examId);
  } else {
    throw new HttpsError('invalid-argument', 'Desteklenmeyen platform.');
  }

  const uid = auth.uid;
  const examSnapshot = await db.collection('exams').doc(examId).get();
  if (!examSnapshot.exists || examSnapshot.get('status') !== 'published') {
    throw new HttpsError('not-found', 'Sınav bulunamadı.');
  }

  return recordPurchasedUnlock(db, { uid, examId, ...purchase });
});

// Verifies the StoreKit 2 signed transaction with Apple before granting anything.
async function verifyAppStorePurchase(data) {
  const signedTransaction = typeof data?.signedTransaction === 'string' ? data.signedTransaction : '';
  if (!signedTransaction) {
    throw new HttpsError('invalid-argument', 'Satın alma bilgisi gerekli.');
  }

  try {
    const { transactionId } = await verifyExamUnlockTransaction(signedTransaction);
    return { transactionId };
  } catch (error) {
    console.error('Exam unlock purchase verification failed:', error);
    throw new HttpsError('failed-precondition', 'Satın alma doğrulanamadı.');
  }
}

// Verifies the Google Play purchase with the Play Developer API before granting anything. A rejected purchase is
// `failed-precondition` (as on iOS); an unreachable Google Play is `unavailable` and missing API access is `internal`,
// so the client can tell a bad purchase from a temporary failure. It consumes nothing on any failure and retries the
// purchase on its next launch.
async function verifyGooglePlayPurchase(data, examId) {
  const purchaseToken = typeof data?.purchaseToken === 'string' ? data.purchaseToken : '';
  if (!purchaseToken) {
    throw new HttpsError('invalid-argument', 'Satın alma bilgisi gerekli.');
  }

  try {
    const { transactionId } = await verifyExamUnlockPurchase({ purchaseToken, productId: data?.productId, examId });
    return { transactionId, store: 'google_play' };
  } catch (error) {
    console.error('Google Play exam unlock verification failed:', error);
    switch (error?.reason) {
      case 'unavailable':
        throw new HttpsError('unavailable', "Google Play'e şu an ulaşılamıyor. Lütfen daha sonra tekrar dene.");
      case 'misconfigured':
        throw new HttpsError('internal', 'Satın alma şu an doğrulanamıyor. Lütfen daha sonra tekrar dene.');
      default:
        throw new HttpsError('failed-precondition', 'Satın alma doğrulanamadı.');
    }
  }
}

// --- Targeted notifications (NOTIFICATIONS.md §4) ---------------------------------------------------------------

// Live dependencies of the notification handlers. The Realtime Database (profiles), FCM and Storage handles are
// created on first use: the RTDB URL and the default bucket come from the deployed function's FIREBASE_CONFIG,
// which a plain import (tests) lacks.
const notificationDeps = {
  db,
  get rtdb() {
    return getDatabase();
  },
  get messaging() {
    return getMessaging();
  },
  // The default bucket, where the admin's app uploads campaign images (`notificationImages/`).
  get bucket() {
    return getStorage().bucket();
  },
  // A V4 signed read URL for a campaign image, valid for 7 days, put only in the FCM payload (never stored). Without
  // a key file the Admin SDK signs through IAM `signBlob`: the functions' service account needs the "Service Account
  // Token Creator" role on itself (NOTIFICATIONS.md §6). Expiry counts from now, so it never exceeds V4's 7-day cap.
  signImageUrl: async (storagePath) => {
    const [url] = await getStorage().bucket().file(storagePath).getSignedUrl({
      version: 'v4',
      action: 'read',
      expires: Date.now() + SIGNED_IMAGE_URL_TTL_MS,
    });
    return url;
  },
  now: () => new Date(),
};

// Admin-only (`admin: true` claim): the audience pickers' tree — names and counts, no personal data.
export const getNotificationAudience = onCall({ region: 'europe-west1' }, (request) =>
  getNotificationAudienceHandler(notificationDeps, request)
);

// Admin-only: how many users (and registered devices) a notification would reach right now.
export const previewNotification = onCall({ region: 'europe-west1' }, (request) =>
  previewNotificationHandler(notificationDeps, request)
);

// Admin-only: records a notification and schedules or delivers it; idempotent per `notificationId`. A large fan-out
// reads every recipient's devices, so it gets more time than the 60 s default.
export const sendNotification = onCall({ region: 'europe-west1', timeoutSeconds: 300 }, (request) =>
  sendNotificationHandler(notificationDeps, request)
);

// Removes a re-registered FCM token from the other accounts that still hold it.
//
// ⚠️ Verify at deploy time: this is the project's first Firestore trigger and it listens to the NAMED `vifi`
// database in the eur3 multi-region. The Eventarc trigger location must match the database location (`eur3`) while
// the function runs in europe-west1; confirm the Firebase CLI resolves it that way (and enables Eventarc and its
// service agent) before relying on it.
export const onDeviceWritten = onDocumentWritten(
  { document: 'users/{uid}/devices/{deviceId}', database: 'vifi', region: 'europe-west1' },
  (event) => onDeviceWrittenHandler(notificationDeps, event)
);

// --- Scheduled notifications (phase 3/G, `notifications/schedule.js`) --------------------------------------------
// Imports are hoisted, so they sit with the block they serve (keeps the parallel tracks' additions apart).
import { onSchedule } from 'firebase-functions/v2/scheduler';
import { cancelNotificationHandler, dispatchScheduledNotificationsHandler } from './notifications/schedule.js';

// Admin-only: cancels a notification that is still `scheduled`; anything else is `failed-precondition`.
export const cancelNotification = onCall({ region: 'europe-west1' }, (request) =>
  cancelNotificationHandler(notificationDeps, request)
);

// Every 5 minutes on the clock in Türkiye (09:00 sharp ends quiet hours): delivers the due scheduled notifications
// and retries deliveries stuck in `sending`. No Cloud Scheduler retries — the next run picks up whatever is left.
export const dispatchScheduledNotifications = onSchedule(
  { schedule: '*/5 * * * *', timeZone: 'Europe/Istanbul', region: 'europe-west1', timeoutSeconds: 540, retryCount: 0 },
  () => dispatchScheduledNotificationsHandler(notificationDeps)
);

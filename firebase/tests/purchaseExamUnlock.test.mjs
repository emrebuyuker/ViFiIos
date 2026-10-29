// `purchaseExamUnlock` against the Firestore emulator: the shared unlock recorder (replay protection, idempotency, the
// record shape of each store) and the callable's guards for both platforms. Store verification itself is covered by
// `appStore.test.mjs` and `googlePlay.test.mjs`; no case here reaches Apple or Google Play.

import { test, before, after, mock } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { assertLocalEmulators } from './helpers.mjs';

// The functions' own firebase-admin (not the test tooling's newer copy), so the recorder's FieldValue sentinels and
// this database handle come from the same SDK instance.
const requireFromFunctions = createRequire(new URL('../functions/package.json', import.meta.url));
const { getFirestore } = requireFromFunctions('firebase-admin/firestore');

let db;
let purchaseExamUnlock;
let recordPurchasedUnlock;

before(async () => {
  assertLocalEmulators('FIRESTORE_EMULATOR_HOST');
  // Rejected purchases are logged by the function; the assertions check them, so keep the expected logs quiet.
  mock.method(console, 'error', () => {});
  ({ purchaseExamUnlock } = await import('../functions/index.js'));
  ({ recordPurchasedUnlock } = await import('../functions/purchaseUnlock.js'));
  db = getFirestore('vifi');
});

after(async () => {
  await db?.terminate();
});

// Each test uses its own ids, so tests never see each other's documents.
let sequence = 0;
const fresh = (prefix) => `${prefix}-${process.pid}-${++sequence}`;

const unlockDoc = (uid, examId) => db.collection('users').doc(uid).collection('unlocks').doc(examId).get();
const transactionDoc = (transactionId) => db.collection('purchasedTransactions').doc(transactionId).get();

/** A callable request from a signed-in +90 user. */
const signedIn = (uid, data) => ({ auth: { uid, token: { phone_number: '+905551112233' } }, data });

async function assertHttpsError(promise, code, message) {
  await assert.rejects(promise, (error) => {
    assert.equal(error.code, code);
    if (message) assert.equal(error.message, message);
    return true;
  });
}

// --- Recorder -----------------------------------------------------------------------------------------------------

test('records an App Store purchase exactly as before (no store tag)', async () => {
  const uid = fresh('ios-user');
  const examId = fresh('exam');
  const transactionId = fresh('2000000');

  assert.deepEqual(await recordPurchasedUnlock(db, { uid, examId, transactionId }), { alreadyUnlocked: false });

  const unlock = (await unlockDoc(uid, examId)).data();
  assert.deepEqual(Object.keys(unlock).sort(), ['createdAt', 'examId', 'source', 'transactionId']);
  assert.equal(unlock.examId, examId);
  assert.equal(unlock.source, 'purchase');
  assert.equal(unlock.transactionId, transactionId);

  const record = (await transactionDoc(transactionId)).data();
  assert.deepEqual(Object.keys(record).sort(), ['createdAt', 'examId', 'uid']);
  assert.equal(record.uid, uid);
  assert.equal(record.examId, examId);
});

test('tags a Google Play purchase with its store on both documents', async () => {
  const uid = fresh('android-user');
  const examId = fresh('exam');
  const transactionId = fresh('GPA.3372');

  await recordPurchasedUnlock(db, { uid, examId, transactionId, store: 'google_play' });

  const unlock = (await unlockDoc(uid, examId)).data();
  assert.equal(unlock.store, 'google_play');
  assert.equal(unlock.source, 'purchase');
  assert.equal(unlock.transactionId, transactionId);
  assert.equal((await transactionDoc(transactionId)).get('store'), 'google_play');
});

test('a retry of the same purchase for the same user and exam is idempotent', async () => {
  const purchase = { uid: fresh('user'), examId: fresh('exam'), transactionId: fresh('GPA'), store: 'google_play' };

  await recordPurchasedUnlock(db, purchase);
  const firstCreatedAt = (await unlockDoc(purchase.uid, purchase.examId)).get('createdAt');

  assert.deepEqual(await recordPurchasedUnlock(db, purchase), { alreadyUnlocked: true });
  assert.deepEqual((await unlockDoc(purchase.uid, purchase.examId)).get('createdAt'), firstCreatedAt);
});

test('a used purchase cannot unlock another exam', async () => {
  const uid = fresh('user');
  const transactionId = fresh('GPA');
  const otherExamId = fresh('exam');
  await recordPurchasedUnlock(db, { uid, examId: fresh('exam'), transactionId, store: 'google_play' });

  await assertHttpsError(
    recordPurchasedUnlock(db, { uid, examId: otherExamId, transactionId, store: 'google_play' }),
    'failed-precondition',
    'Bu satın alma zaten kullanıldı.'
  );
  assert.equal((await unlockDoc(uid, otherExamId)).exists, false);
});

test('a used purchase cannot unlock the same exam for another user', async () => {
  const examId = fresh('exam');
  const transactionId = fresh('GPA');
  const otherUid = fresh('user');
  await recordPurchasedUnlock(db, { uid: fresh('user'), examId, transactionId, store: 'google_play' });

  await assertHttpsError(
    recordPurchasedUnlock(db, { uid: otherUid, examId, transactionId, store: 'google_play' }),
    'failed-precondition'
  );
  assert.equal((await unlockDoc(otherUid, examId)).exists, false);
});

test('a purchase for an exam already unlocked with coins is consumed without rewriting the unlock', async () => {
  const uid = fresh('user');
  const examId = fresh('exam');
  const transactionId = fresh('GPA');
  const coinUnlock = { examId, coinsSpent: 100 };
  await db.collection('users').doc(uid).collection('unlocks').doc(examId).set(coinUnlock);

  assert.deepEqual(
    await recordPurchasedUnlock(db, { uid, examId, transactionId, store: 'google_play' }),
    { alreadyUnlocked: true }
  );
  assert.deepEqual((await unlockDoc(uid, examId)).data(), coinUnlock);
  assert.equal((await transactionDoc(transactionId)).get('examId'), examId);
});

// --- Callable guards ----------------------------------------------------------------------------------------------

test('requires a signed-in +90 user', async () => {
  const data = { platform: 'android', purchaseToken: 't', productId: 'exam_unlock', examId: 'e' };
  await assertHttpsError(purchaseExamUnlock.run({ data }), 'permission-denied');
  await assertHttpsError(
    purchaseExamUnlock.run({ auth: { uid: 'u', token: { phone_number: '+15551234567' } }, data }),
    'permission-denied'
  );
});

test('requires an exam id on both platforms', async () => {
  await assertHttpsError(purchaseExamUnlock.run(signedIn('u', { signedTransaction: 'x' })), 'invalid-argument');
  await assertHttpsError(
    purchaseExamUnlock.run(signedIn('u', { platform: 'android', purchaseToken: 't', productId: 'exam_unlock', examId: ' ' })),
    'invalid-argument'
  );
});

test('rejects an unknown platform', async () => {
  await assertHttpsError(
    purchaseExamUnlock.run(signedIn('u', { platform: 'web', examId: 'e', purchaseToken: 't' })),
    'invalid-argument',
    'Desteklenmeyen platform.'
  );
});

test('iOS path is unchanged: requires and verifies the signed transaction', async () => {
  for (const platform of [undefined, 'ios']) {
    await assertHttpsError(
      purchaseExamUnlock.run(signedIn('u', { platform, examId: 'e' })),
      'invalid-argument',
      'Satın alma bilgisi gerekli.'
    );
    await assertHttpsError(
      purchaseExamUnlock.run(signedIn('u', { platform, examId: 'e', signedTransaction: 'eyJhbGciOiJFUzI1NiJ9.e30.c2ln' })),
      'failed-precondition',
      'Satın alma doğrulanamadı.'
    );
  }
});

test('Android path requires a purchase token', async () => {
  for (const purchaseToken of [undefined, '', 7]) {
    await assertHttpsError(
      purchaseExamUnlock.run(signedIn('u', { platform: 'android', examId: 'e', productId: 'exam_unlock', purchaseToken })),
      'invalid-argument',
      'Satın alma bilgisi gerekli.'
    );
  }
});

test('Android path rejects another product before reaching Google Play', async () => {
  await assertHttpsError(
    purchaseExamUnlock.run(signedIn('u', { platform: 'android', examId: 'e', productId: 'vifi_premium', purchaseToken: 't' })),
    'failed-precondition',
    'Satın alma doğrulanamadı.'
  );
});

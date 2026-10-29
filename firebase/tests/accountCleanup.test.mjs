// The account-deletion cleanup (`functions/accountCleanup.js`) against the Firestore, Realtime Database and Storage
// emulators: what a deleted account loses (per-user Firestore data, wallet + ledger, subscription, pending
// submissions and their uploads, the RTDB profile), what is kept (published archive, reviewed submissions, other
// users) or only unlinked (consumed purchase transactions), idempotent re-runs, partial failures and the uid guard.

import { test, before, after, beforeEach, describe, mock } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { assertLocalEmulators, PROJECT_ID } from './helpers.mjs';

const requireFromFunctions = createRequire(new URL('../functions/package.json', import.meta.url));
const { getFirestore } = requireFromFunctions('firebase-admin/firestore');
const { getDatabase } = requireFromFunctions('firebase-admin/database');
const { getStorage } = requireFromFunctions('firebase-admin/storage');
const { getApp, deleteApp } = requireFromFunctions('firebase-admin/app');

const GONE = 'goneUser123';
const STAY = 'stayUser456';

let db;
let rtdb;
let bucket;
let fns;
let cleanup;
let purchaseUnlock;

before(async () => {
  assertLocalEmulators('FIRESTORE_EMULATOR_HOST', 'FIREBASE_DATABASE_EMULATOR_HOST', 'FIREBASE_STORAGE_EMULATOR_HOST');
  mock.method(console, 'error', () => {});
  mock.method(console, 'warn', () => {});
  mock.method(console, 'info', () => {});
  fns = await import('../functions/index.js');
  cleanup = await import('../functions/accountCleanup.js');
  purchaseUnlock = await import('../functions/purchaseUnlock.js');
  db = getFirestore('vifi');
  // The emulator run's FIREBASE_CONFIG defaults: the same database and bucket the deployed trigger uses.
  rtdb = getDatabase();
  bucket = getStorage().bucket();
});

after(async () => {
  await deleteApp(getApp());
});

// --- Fixtures -----------------------------------------------------------------------------------------------------

const PENDING_FILES = [
  `pending/${GONE}/s-pending/0.jpg`,
  `pending/${GONE}/s-pending/1.jpg`,
  `pending/${GONE}/s-rejected/0.jpg`,
  `pending/${GONE}/orphan-upload/0.pdf`,
];
const KEPT_FILES = [`pending/${STAY}/s-other/0.jpg`, 'imagess/archive.jpg', `pending/${GONE}x/s/0.jpg`];

async function clearFirestore() {
  const host = process.env.FIRESTORE_EMULATOR_HOST;
  const response = await fetch(`http://${host}/emulator/v1/projects/${PROJECT_ID}/databases/vifi/documents`, { method: 'DELETE' });
  assert.ok(response.ok, `clearing the Firestore emulator failed: ${response.status}`);
}

function submission(ownerId, status) {
  return {
    ownerId, university: 'Ege Üniversitesi', faculty: 'Mühendislik Fakültesi', department: 'Bilgisayar Mühendisliği',
    lesson: 'Algoritmalar', exam: '2024 FİNAL', kind: 'JPG', status, createdAt: new Date(),
    files: [{ storagePath: `pending/${ownerId}/x/0.jpg`, order: 0 }],
  };
}

async function seedUser(uid) {
  const user = db.collection('users').doc(uid);
  const writer = db.bulkWriter();
  writer.set(user.collection('unlocks').doc('exam-1'), { examId: 'exam-1', coinsSpent: 100, createdAt: new Date() });
  writer.set(user.collection('inbox').doc('n-1'), { kind: 'system', title: 'Başlık', body: 'Mesaj', createdAt: new Date() });
  writer.set(user.collection('devices').doc('d-1'), { token: `tok-${uid}`, platform: 'ios', appVersion: '4.1.0', updatedAt: new Date() });
  writer.set(user.collection('settings').doc('notifications'), { marketing: true, source: 'prompt', version: 1, updatedAt: new Date() });
  writer.set(user.collection('settings').doc('inbox'), { readAt: new Date() });
  writer.set(db.collection('wallets').doc(uid), { balance: 150, updatedAt: new Date() });
  writer.set(db.collection('wallets').doc(uid).collection('ledger').doc('sub-1'), { type: 'earn', amount: 50, createdAt: new Date() });
  writer.set(db.collection('subscriptions').doc(uid), { active: true });
  await writer.close();
  await rtdb.ref('users').child(uid).set({ profile: { name: 'Ad', surname: 'Soyad', universityId: 'ege-universitesi' } });
  // A legacy (pre-Firestore) RTDB submission queue entry.
  await rtdb.ref('pendingExams').child(uid).child('old-1').set({ status: 'pending', lesson: 'Ders' });
}

beforeEach(async () => {
  await clearFirestore();
  await rtdb.ref('users').remove();
  await rtdb.ref('pendingExams').remove();
  await bucket.deleteFiles({ prefix: 'pending/' });
  await bucket.deleteFiles({ prefix: 'imagess/' });

  await seedUser(GONE);
  await seedUser(STAY);
  const writer = db.bulkWriter();
  writer.set(db.collection('submissions').doc('s-pending'), submission(GONE, 'pending'));
  writer.set(db.collection('submissions').doc('s-approved'), { ...submission(GONE, 'approved'), publishedExamId: 'exam-1' });
  writer.set(db.collection('submissions').doc('s-rejected'), { ...submission(GONE, 'rejected'), rejectionReason: 'Okunmuyor' });
  writer.set(db.collection('submissions').doc('s-other'), submission(STAY, 'pending'));
  writer.set(db.collection('purchasedTransactions').doc('tx-gone'), { uid: GONE, examId: 'exam-1', createdAt: new Date() });
  writer.set(db.collection('purchasedTransactions').doc('tx-stay'), { uid: STAY, examId: 'exam-2', createdAt: new Date() });
  writer.set(db.collection('exams').doc('exam-1'), { title: '2024 FİNAL', status: 'published', kind: 'JPG', source: 'submission' });
  writer.set(db.collection('catalogNodes').doc('ege-universitesi'), { name: 'Ege Üniversitesi', parentId: '', status: 'published' });
  await writer.close();
  for (const path of [...PENDING_FILES, ...KEPT_FILES]) {
    await bucket.file(path).save(Buffer.from('x'), { contentType: path.endsWith('.pdf') ? 'application/pdf' : 'image/jpeg', resumable: false });
  }
});

const exists = async (ref) => (await ref.get()).exists;

async function filesUnder(prefix) {
  const [files] = await bucket.getFiles({ prefix });
  return files.map((file) => file.name).sort();
}

async function userCollections(uid) {
  return (await db.collection('users').doc(uid).listCollections()).map((collection) => collection.id).sort();
}

/** Asserts the state after `GONE` was cleaned up and `STAY` was left alone. */
async function assertCleanedUp() {
  assert.deepEqual(await userCollections(GONE), []);
  assert.equal(await exists(db.collection('wallets').doc(GONE)), false);
  assert.equal((await db.collection('wallets').doc(GONE).collection('ledger').get()).size, 0);
  assert.equal(await exists(db.collection('subscriptions').doc(GONE)), false);
  assert.equal(await exists(db.collection('submissions').doc('s-pending')), false);
  assert.equal((await rtdb.ref('users').child(GONE).once('value')).exists(), false);
  assert.equal((await rtdb.ref('pendingExams').child(GONE).once('value')).exists(), false);
  assert.deepEqual(await filesUnder(`pending/${GONE}/`), []);

  // Unlinked, not deleted: the purchase still cannot be replayed.
  const purchase = (await db.collection('purchasedTransactions').doc('tx-gone').get()).data();
  assert.equal('uid' in purchase, false);
  assert.equal(purchase.examId, 'exam-1');
  assert.ok(purchase.accountDeletedAt);

  // Kept: the archive, reviewed submissions and everyone else's data.
  assert.equal(await exists(db.collection('exams').doc('exam-1')), true);
  assert.equal(await exists(db.collection('catalogNodes').doc('ege-universitesi')), true);
  assert.equal((await db.collection('submissions').doc('s-approved').get()).get('ownerId'), GONE);
  assert.equal((await db.collection('submissions').doc('s-rejected').get()).get('ownerId'), GONE);
  assert.equal(await exists(db.collection('submissions').doc('s-other')), true);
  assert.deepEqual(await userCollections(STAY), ['devices', 'inbox', 'settings', 'unlocks']);
  assert.equal((await db.collection('wallets').doc(STAY).get()).get('balance'), 150);
  assert.equal((await db.collection('wallets').doc(STAY).collection('ledger').get()).size, 1);
  assert.equal(await exists(db.collection('subscriptions').doc(STAY)), true);
  assert.equal((await db.collection('purchasedTransactions').doc('tx-stay').get()).get('uid'), STAY);
  assert.equal((await rtdb.ref('users').child(STAY).child('profile/name').once('value')).val(), 'Ad');
  assert.equal((await rtdb.ref('pendingExams').child(STAY).child('old-1/lesson').once('value')).val(), 'Ders');
  for (const path of KEPT_FILES) assert.deepEqual(await filesUnder(path), [path]);
}

// --- Tests --------------------------------------------------------------------------------------------------------

describe('deleteAccountData', () => {
  test('deletes the account\'s data, unlinks its purchases and keeps everything else', async () => {
    const summary = await cleanup.deleteAccountData({ db, rtdb, bucket }, GONE);
    assert.deepEqual(summary, { uid: GONE, pendingSubmissions: 1, unlinkedPurchases: 1 });
    await assertCleanedUp();
  });

  test('a re-run (a retried event) is a no-op that still succeeds', async () => {
    await cleanup.deleteAccountData({ db, rtdb, bucket }, GONE);
    const again = await cleanup.deleteAccountData({ db, rtdb, bucket }, GONE);
    assert.deepEqual(again, { uid: GONE, pendingSubmissions: 0, unlinkedPurchases: 0 });
    await assertCleanedUp();
  });

  test('an unlinked purchase transaction still cannot unlock again, for anyone', async () => {
    await cleanup.deleteAccountData({ db, rtdb, bucket }, GONE);
    await assert.rejects(
      purchaseUnlock.recordPurchasedUnlock(db, { uid: 'newAccount789', examId: 'exam-1', transactionId: 'tx-gone' }),
      (error) => error.code === 'failed-precondition' && error.message === 'Bu satın alma zaten kullanıldı.'
    );
  });

  test('a failing step does not stop the others; the error makes the trigger retry, and the retry finishes', async () => {
    const brokenBucket = { deleteFiles: async () => { throw new Error('storage unavailable'); } };
    await assert.rejects(cleanup.deleteAccountData({ db, rtdb, bucket: brokenBucket }, GONE), (error) => {
      assert.ok(error instanceof AggregateError);
      assert.match(error.message, /pendingFiles/);
      return true;
    });
    // Everything else is already gone; only the uploads are left.
    assert.deepEqual(await userCollections(GONE), []);
    assert.equal(await exists(db.collection('submissions').doc('s-pending')), false);
    assert.equal((await filesUnder(`pending/${GONE}/`)).length, PENDING_FILES.length);

    await cleanup.deleteAccountData({ db, rtdb, bucket }, GONE);
    await assertCleanedUp();
  });

  test('a uid that is not a single path segment is refused and touches nothing', async () => {
    for (const uid of ['', `${GONE}/unlocks`, '..', 'a.b', undefined]) {
      assert.deepEqual(await cleanup.deleteAccountData({ db, rtdb, bucket }, uid), { skipped: 'unsupported-uid' });
    }
    assert.deepEqual(await userCollections(GONE), ['devices', 'inbox', 'settings', 'unlocks']);
    assert.equal(await exists(db.collection('submissions').doc('s-pending')), true);
    assert.equal((await filesUnder(`pending/${GONE}/`)).length, PENDING_FILES.length);
  });

  test('the deployed Auth deletion trigger runs the cleanup with the live dependencies', async () => {
    const summary = await fns.onAccountDeleted.run({ uid: GONE }, { eventType: 'providers/firebase.auth/eventTypes/user.delete' });
    assert.deepEqual(summary, { uid: GONE, pendingSubmissions: 1, unlinkedPurchases: 1 });
    await assertCleanedUp();
  });
});

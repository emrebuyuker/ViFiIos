// Cloud Firestore security rules tests (firestore.rules), run against the local emulator.
//
// Built incrementally alongside the rules:
//   - deny-by-default skeleton (item #5)
//   - archive read: catalogNodes + exams (item #6)
// submissions (#7) and coin/entitlement/notification collections (#8) are still denied here.

import { after, before, beforeEach, describe, test } from 'node:test';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import { contextFor, createFirestoreEnvironment, users } from './helpers.mjs';

let env;

before(async () => {
  env = await createFirestoreEnvironment();
});

after(async () => {
  await env?.cleanup();
});

const db = (user) => contextFor(env, user).firestore();

describe('Firestore rules — deny-by-default for unopened paths', () => {
  // Anonymous, a signed-in +90 phone user, and an admin: none may touch an undefined path.
  for (const [label, user] of [['anonymous', null], ['a +90 user', users.alice], ['an admin', users.admin]]) {
    test(`denies reads and writes on an undefined path for ${label}`, async () => {
      await assertFails(db(user).collection('foo').doc('bar').get());
      await assertFails(db(user).collection('foo').doc('bar').set({ value: 1 }));
    });
  }

  test('a collection that no rule defines stays fully denied, even for an admin', async () => {
    for (const collection of ['events', 'auditLogs']) {
      await assertFails(db(users.admin).collection(collection).doc('x').get());
      await assertFails(db(users.admin).collection(collection).doc('x').set({ value: 1 }));
    }
  });
});

describe('Firestore rules — archive read (catalogNodes, exams)', () => {
  beforeEach(async () => {
    await env.clearFirestore();
    await env.withSecurityRulesDisabled(async (context) => {
      const seed = context.firestore();
      await seed.collection('catalogNodes').doc('bozok').set({
        name: 'BOZOK ÜNİVERSİTESİ', parentId: '', status: 'published', childCount: 1,
      });
      await seed.collection('exams').doc('e1').set({
        title: '2019 FİNAL', courseId: 'c1', kind: 'JPG', status: 'published',
        files: [{ storagePath: 'imagess/a.jpg', order: 0 }],
      });
    });
  });

  test('a +90 phone user can get and list catalog nodes and exams', async () => {
    const fs = db(users.alice);
    await assertSucceeds(fs.collection('catalogNodes').doc('bozok').get());
    await assertSucceeds(fs.collection('catalogNodes').where('parentId', '==', '').where('status', '==', 'published').get());
    await assertSucceeds(fs.collection('exams').doc('e1').get());
    await assertSucceeds(fs.collection('exams').where('courseId', '==', 'c1').where('status', '==', 'published').get());
  });

  test('an admin can read and write the archive', async () => {
    const fs = db(users.admin);
    await assertSucceeds(fs.collection('catalogNodes').doc('bozok').get());
    await assertSucceeds(fs.collection('catalogNodes').doc('new').set({ name: 'X', parentId: '', status: 'published', childCount: 0 }));
    await assertSucceeds(fs.collection('exams').doc('e2').set({ title: 'Y', courseId: 'c1', kind: 'PDF', status: 'published', files: [] }));
  });

  test('non-+90, email-only, short-+90 and anonymous users cannot read the archive', async () => {
    for (const user of [users.usPhone, users.emailOnly, users.shortTrPhone, null]) {
      await assertFails(db(user).collection('catalogNodes').doc('bozok').get());
      await assertFails(db(user).collection('exams').doc('e1').get());
    }
  });

  test('a +90 user cannot write the archive', async () => {
    const fs = db(users.alice);
    await assertFails(fs.collection('catalogNodes').doc('x').set({ name: 'X', parentId: '', status: 'published', childCount: 0 }));
    await assertFails(fs.collection('exams').doc('x').set({ title: 'X', courseId: 'c1', kind: 'JPG', status: 'published', files: [] }));
  });

  test('a forged admin claim (string "true") reads as a +90 user but cannot write', async () => {
    // fakeAdmin has a valid +90 phone, so it can READ; admin:'true' (string) is not admin, so no write.
    await assertSucceeds(db(users.fakeAdmin).collection('exams').doc('e1').get());
    await assertFails(db(users.fakeAdmin).collection('catalogNodes').doc('x').set({ name: 'X', parentId: '', status: 'published', childCount: 0 }));
  });
});

describe('Firestore rules — submissions (create, read, moderate)', () => {
  const validSubmission = (uid, overrides = {}) => ({
    ownerId: uid,
    university: 'Boğaziçi Üniversitesi',
    faculty: 'Mühendislik Fakültesi',
    department: 'Bilgisayar Mühendisliği',
    lesson: 'Veri Yapıları',
    exam: '2019 Final',
    kind: 'JPG',
    status: 'pending',
    createdAt: new Date(),
    files: [{ storagePath: `pending/${uid}/s1/page-1.jpg`, order: 0 }],
    ...overrides,
  });

  beforeEach(async () => {
    await env.clearFirestore();
    await env.withSecurityRulesDisabled(async (context) => {
      const seed = context.firestore();
      await seed.collection('submissions').doc('bob-pending').set(validSubmission('bob'));
      await seed.collection('submissions').doc('alice-pending').set(validSubmission('alice'));
      await seed.collection('submissions').doc('alice-approved').set(validSubmission('alice', { status: 'approved' }));
    });
  });

  test('a +90 owner can create a valid pending submission', async () => {
    await assertSucceeds(db(users.alice).collection('submissions').doc('new').set(validSubmission('alice')));
  });

  test('create is rejected for a wrong owner, non-pending status, bad kind, extra field, no files or bad timestamp', async () => {
    const fs = db(users.alice);
    await assertFails(fs.collection('submissions').doc('a').set(validSubmission('bob')));
    await assertFails(fs.collection('submissions').doc('b').set(validSubmission('alice', { status: 'approved' })));
    await assertFails(fs.collection('submissions').doc('c').set(validSubmission('alice', { kind: 'GIF' })));
    await assertFails(fs.collection('submissions').doc('d').set(validSubmission('alice', { rewardCoins: 5 })));
    await assertFails(fs.collection('submissions').doc('e').set(validSubmission('alice', { files: [] })));
    await assertFails(fs.collection('submissions').doc('f').set(validSubmission('alice', { createdAt: 'not-a-timestamp' })));
  });

  test('an owner reads only their own submissions', async () => {
    const fs = db(users.alice);
    await assertSucceeds(fs.collection('submissions').doc('alice-pending').get());
    await assertFails(fs.collection('submissions').doc('bob-pending').get());
    await assertSucceeds(fs.collection('submissions').where('ownerId', '==', 'alice').get());
    await assertFails(fs.collection('submissions').get());
  });

  test('an owner withdraws a pending submission, but not an approved one or someone else\'s', async () => {
    await assertSucceeds(db(users.alice).collection('submissions').doc('alice-pending').delete());
    await assertFails(db(users.alice).collection('submissions').doc('alice-approved').delete());
    await assertFails(db(users.alice).collection('submissions').doc('bob-pending').delete());
  });

  test('an admin reads all and moderates; a +90 user cannot moderate', async () => {
    await assertSucceeds(db(users.admin).collection('submissions').get());
    await assertSucceeds(db(users.admin).collection('submissions').doc('bob-pending').update({ status: 'approved' }));
    await assertFails(db(users.alice).collection('submissions').doc('bob-pending').update({ status: 'approved' }));
  });

  test('non-+90 and anonymous users cannot create or read submissions', async () => {
    for (const user of [users.usPhone, users.emailOnly, null]) {
      await assertFails(db(user).collection('submissions').doc('x').set(validSubmission(user ? user.uid : 'anon')));
      await assertFails(db(user).collection('submissions').doc('alice-pending').get());
    }
  });
});

describe('Firestore rules — coin / entitlement / notification (server-only)', () => {
  const wallet = (fs, uid) => fs.collection('wallets').doc(uid);
  const ledger = (fs, uid, id) => fs.collection('wallets').doc(uid).collection('ledger').doc(id);
  const sub = (fs, uid) => fs.collection('subscriptions').doc(uid);
  const unlock = (fs, uid, examId) => fs.collection('users').doc(uid).collection('unlocks').doc(examId);
  const inbox = (fs, uid, id) => fs.collection('users').doc(uid).collection('inbox').doc(id);
  const device = (fs, uid, token) => fs.collection('users').doc(uid).collection('devices').doc(token);

  beforeEach(async () => {
    await env.clearFirestore();
    await env.withSecurityRulesDisabled(async (context) => {
      const seed = context.firestore();
      await wallet(seed, 'alice').set({ coinBalance: 10 });
      await ledger(seed, 'alice', 'e1').set({ type: 'earn', amount: 10, balanceAfter: 10 });
      await sub(seed, 'alice').set({ active: true });
      await unlock(seed, 'alice', 'exam1').set({ coinsSpent: 5 });
      await inbox(seed, 'alice', 'm1').set({ title: 'Merhaba', body: 'x', read: false });
      await device(seed, 'alice', 'tok1').set({ platform: 'ios' });
    });
  });

  test('an owner reads their money/entitlement state but can never write it', async () => {
    const fs = db(users.alice);
    await assertSucceeds(wallet(fs, 'alice').get());
    await assertSucceeds(ledger(fs, 'alice', 'e1').get());
    await assertSucceeds(sub(fs, 'alice').get());
    await assertSucceeds(unlock(fs, 'alice', 'exam1').get());
    await assertFails(wallet(fs, 'alice').set({ coinBalance: 9999 }));
    await assertFails(wallet(fs, 'alice').update({ coinBalance: 9999 }));
    await assertFails(ledger(fs, 'alice', 'e2').set({ type: 'earn', amount: 9999 }));
    await assertFails(sub(fs, 'alice').set({ active: true }));
    await assertFails(unlock(fs, 'alice', 'exam2').set({ coinsSpent: 0 }));
  });

  test('a user cannot read another user\'s money/entitlement state', async () => {
    const fs = db(users.bob);
    await assertFails(wallet(fs, 'alice').get());
    await assertFails(ledger(fs, 'alice', 'e1').get());
    await assertFails(sub(fs, 'alice').get());
    await assertFails(unlock(fs, 'alice', 'exam1').get());
  });

  test('even an admin cannot write money/entitlement state from a client', async () => {
    const fs = db(users.admin);
    await assertSucceeds(wallet(fs, 'alice').get());
    await assertFails(wallet(fs, 'alice').set({ coinBalance: 9999 }));
    await assertFails(ledger(fs, 'alice', 'e2').set({ amount: 1 }));
    await assertFails(sub(fs, 'alice').set({ active: true }));
    await assertFails(unlock(fs, 'alice', 'exam2').set({ coinsSpent: 0 }));
  });

  test('the inbox: the owner may flip only the read flag, never create, delete or change other fields', async () => {
    const fs = db(users.alice);
    await assertSucceeds(inbox(fs, 'alice', 'm1').get());
    await assertSucceeds(inbox(fs, 'alice', 'm1').update({ read: true }));
    await assertFails(inbox(fs, 'alice', 'm1').update({ read: true, title: 'hack' }));
    await assertFails(inbox(fs, 'alice', 'm1').update({ title: 'hack' }));
    await assertFails(inbox(fs, 'alice', 'new').set({ title: 'x', read: false }));
    await assertFails(inbox(fs, 'alice', 'm1').delete());
    await assertFails(inbox(db(users.bob), 'alice', 'm1').get());
  });

  test('device tokens: the owner manages their own; others cannot', async () => {
    await assertSucceeds(device(db(users.alice), 'alice', 'tok1').get());
    await assertSucceeds(device(db(users.alice), 'alice', 'tok2').set({ platform: 'ios' }));
    await assertSucceeds(device(db(users.alice), 'alice', 'tok1').delete());
    await assertFails(device(db(users.bob), 'alice', 'tok1').get());
    await assertFails(device(db(users.bob), 'alice', 'tok3').set({ platform: 'ios' }));
  });
});

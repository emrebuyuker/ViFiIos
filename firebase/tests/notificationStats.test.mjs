// `trackNotificationEvent` (functions/notifications/stats.js) against the Firestore emulators: the +90 gate, input
// validation, the recipient check for fan-out and broadcast notifications, once-per-user dedupe (also under
// concurrent retries), the counters and marker documents it writes, and that real deliveries from
// `sendNotification` carry the counters it increments. FCM is a fake; nothing leaves this machine.

import { test, before, after, beforeEach, describe, mock } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { PROJECT_ID, assertLocalEmulators } from './helpers.mjs';

// The functions' own firebase-admin, so sentinels and snapshots come from the same SDK instance as the code under test.
const requireFromFunctions = createRequire(new URL('../functions/package.json', import.meta.url));
const { getFirestore } = requireFromFunctions('firebase-admin/firestore');
const { getDatabaseWithUrl } = requireFromFunctions('firebase-admin/database');
const { getApp, deleteApp } = requireFromFunctions('firebase-admin/app');

const DAY = new Date('2026-10-29T09:00:00Z'); // 12:00 in Türkiye, outside quiet hours
const ADMIN_UID = 'admin-1';

const ALICE = { uid: 'alice', phone: '+905551112233' };
const MEHMET = { uid: 'mehmet', phone: '+905559998877' };
const ALI = { uid: 'ali', phone: '+905550001122' };

let db;
let rtdb;
let fns;
let admin;
let stats;

before(async () => {
  assertLocalEmulators('FIRESTORE_EMULATOR_HOST', 'FIREBASE_DATABASE_EMULATOR_HOST');
  // Expected failures are logged by the functions; keep the test output readable.
  mock.method(console, 'error', () => {});
  mock.method(console, 'warn', () => {});
  fns = await import('../functions/index.js');
  admin = await import('../functions/notifications/admin.js');
  stats = await import('../functions/notifications/stats.js');
  db = getFirestore('vifi');
  rtdb = getDatabaseWithUrl(`https://${PROJECT_ID}-default-rtdb.firebaseio.com`);
});

after(async () => {
  await deleteApp(getApp());
});

async function clearFirestore() {
  const host = process.env.FIRESTORE_EMULATOR_HOST;
  const response = await fetch(`http://${host}/emulator/v1/projects/${PROJECT_ID}/databases/vifi/documents`, { method: 'DELETE' });
  assert.ok(response.ok, `clearing the Firestore emulator failed: ${response.status}`);
}

beforeEach(clearFirestore);

// --- Fixtures -----------------------------------------------------------------------------------------------------

let sequence = 0;
const freshId = () => `stat-${process.pid}-${++sequence}`;

const asUser = ({ uid, phone }, data) => ({ auth: { uid, token: { phone_number: phone } }, data });
const track = (user, notificationId, event) => stats.trackNotificationEventHandler({ db }, asUser(user, { notificationId, event }));

const notificationRef = (id) => db.collection('notifications').doc(id);
const eventRef = (id, uid, event) => notificationRef(id).collection('events').doc(`${uid}_${event}`);
const counters = async (id) => {
  const { opened, actionTapped } = (await notificationRef(id).get()).get('stats');
  return { opened, actionTapped };
};

/** A delivered fan-out notification: its record plus an inbox copy for each of `uids`. */
async function seedFanout(uids, id = freshId()) {
  await notificationRef(id).set({
    kind: 'general', title: 'Başlık', body: 'Mesaj', delivery: 'fanout', status: 'sent',
    stats: { recipients: uids.length, pushTargets: 0, pushSent: 0, pushFailed: 0, opened: 0, actionTapped: 0 },
  });
  for (const uid of uids) {
    await db.collection('users').doc(uid).collection('inbox').doc(id).set({ kind: 'general', title: 'Başlık', body: 'Mesaj', createdAt: new Date() });
  }
  return id;
}

/** A delivered broadcast notification: its record plus the public announcement. */
async function seedBroadcast(id = freshId()) {
  await notificationRef(id).set({
    kind: 'general', title: 'Duyuru', body: 'Mesaj', delivery: 'broadcast', status: 'sent',
    stats: { recipients: 4, pushTargets: 0, pushSent: 0, pushFailed: 0, opened: 0, actionTapped: 0 },
  });
  await db.collection('announcements').doc(id).set({ kind: 'general', title: 'Duyuru', body: 'Mesaj', createdAt: new Date() });
  return id;
}

async function assertHttpsError(promise, code, message) {
  await assert.rejects(promise, (error) => {
    assert.equal(error.code, code);
    if (message) assert.equal(error.message, message);
    return true;
  });
}

// --- Gate and validation ------------------------------------------------------------------------------------------

describe('caller gate and input validation', () => {
  test('only signed-in +90 phone users may report', async () => {
    const id = await seedFanout([ALICE.uid]);
    const callers = [
      undefined,
      { uid: 'u1', token: {} },
      { uid: 'u2', token: { email: 'someone@example.com', email_verified: true } },
      { uid: 'u3', token: { phone_number: '+15551234567' } },
      { uid: 'u4', token: { phone_number: '+90555111223' } },
      { uid: 'u5', token: { phone_number: '+9055511122334' } },
      { uid: ADMIN_UID, token: { admin: true } },
    ];
    for (const auth of callers) {
      await assertHttpsError(
        stats.trackNotificationEventHandler({ db }, { auth, data: { notificationId: id, event: 'opened' } }),
        'permission-denied',
        'Bu işlem için giriş yapmış olman gerekiyor.'
      );
    }
    assert.deepEqual(await counters(id), { opened: 0, actionTapped: 0 });
  });

  test('the notification id must be well-formed', async () => {
    const bad = [undefined, null, 42, '', ' ', 'a/b', 'has space', 'x'.repeat(129), '../users/alice', { id: 'x' }];
    for (const notificationId of bad) {
      await assertHttpsError(track(ALICE, notificationId, 'opened'), 'invalid-argument', 'Geçersiz bildirim kimliği.');
    }
    await assertHttpsError(
      stats.trackNotificationEventHandler({ db }, { auth: asUser(ALICE).auth, data: undefined }),
      'invalid-argument',
      'Geçersiz bildirim kimliği.'
    );
  });

  test('only opened and actionTapped are accepted', async () => {
    const id = await seedFanout([ALICE.uid]);
    for (const event of [undefined, null, '', 'delivered', 'Opened', 'stats.recipients', 'pushSent', 7, ['opened']]) {
      await assertHttpsError(track(ALICE, id, event), 'invalid-argument', 'Geçersiz olay türü.');
    }
    assert.deepEqual(await counters(id), { opened: 0, actionTapped: 0 });
    assert.equal((await notificationRef(id).get()).get('stats.recipients'), 1);
  });

  test('the deployed callable runs the same handler', async () => {
    const id = await seedFanout([ALICE.uid]);
    assert.deepEqual(await fns.trackNotificationEvent.run(asUser(ALICE, { notificationId: id, event: 'opened' })), { counted: true });
    await assertHttpsError(
      fns.trackNotificationEvent.run({ data: { notificationId: id, event: 'opened' } }),
      'permission-denied'
    );
  });
});

// --- Recipient check ----------------------------------------------------------------------------------------------

describe('recipients', () => {
  test('an unknown notification is not-found', async () => {
    await assertHttpsError(track(ALICE, freshId(), 'opened'), 'not-found', 'Bildirim bulunamadı.');
  });

  test('a fan-out is countable only by the users whose inbox holds it, and the answer does not reveal it exists', async () => {
    const id = await seedFanout([ALICE.uid]);
    const unknown = await track(MEHMET, freshId(), 'opened').catch((error) => error);
    const notRecipient = await track(MEHMET, id, 'opened').catch((error) => error);

    assert.equal(notRecipient.code, 'not-found');
    // Byte-identical to the unknown-id answer: nothing tells an outsider which ids are real.
    assert.equal(notRecipient.code, unknown.code);
    assert.equal(notRecipient.message, unknown.message);

    assert.deepEqual(await counters(id), { opened: 0, actionTapped: 0 });
    assert.equal((await eventRef(id, MEHMET.uid, 'opened').get()).exists, false);
  });

  test('a fan-out is judged by the caller\'s own inbox copy, never another user\'s', async () => {
    const id = await seedFanout([ALICE.uid]);
    // Mehmet cannot borrow Alice's copy by passing her id anywhere: only `uid` from the verified token is used.
    await assertHttpsError(track(MEHMET, id, 'actionTapped'), 'not-found');
    assert.deepEqual(await track(ALICE, id, 'actionTapped'), { counted: true });
  });

  test('a broadcast counts for any +90 user once its announcement exists', async () => {
    const id = await seedBroadcast();
    assert.deepEqual(await track(ALICE, id, 'opened'), { counted: true });
    assert.deepEqual(await track(MEHMET, id, 'opened'), { counted: true });
    assert.deepEqual(await counters(id), { opened: 2, actionTapped: 0 });
  });

  test('a broadcast whose announcement was never written is not-found', async () => {
    const id = await seedBroadcast();
    await db.collection('announcements').doc(id).delete();
    await assertHttpsError(track(ALICE, id, 'opened'), 'not-found');
    assert.deepEqual(await counters(id), { opened: 0, actionTapped: 0 });
  });

  test('the copy checked follows the notification\'s delivery mode', async () => {
    // A fan-out is not made countable by a public announcement with the same id, and a broadcast is not made
    // countable by a stray inbox copy.
    const fanout = await seedFanout([ALICE.uid]);
    await db.collection('announcements').doc(fanout).set({ title: 'x', body: 'y', createdAt: new Date() });
    await assertHttpsError(track(MEHMET, fanout, 'opened'), 'not-found');

    const broadcast = await seedBroadcast();
    await db.collection('announcements').doc(broadcast).delete();
    await db.collection('users').doc(ALICE.uid).collection('inbox').doc(broadcast).set({ title: 'x', body: 'y', createdAt: new Date() });
    await assertHttpsError(track(ALICE, broadcast, 'opened'), 'not-found');
  });
});

// --- Counting and dedupe ------------------------------------------------------------------------------------------

describe('counting', () => {
  test('the first report counts and leaves its marker; a repeat changes nothing', async () => {
    const id = await seedFanout([ALICE.uid, MEHMET.uid]);

    assert.deepEqual(await track(ALICE, id, 'opened'), { counted: true });
    assert.deepEqual(await counters(id), { opened: 1, actionTapped: 0 });

    const marker = await eventRef(id, ALICE.uid, 'opened').get();
    assert.equal(marker.exists, true);
    assert.deepEqual(Object.keys(marker.data()).sort(), ['createdAt', 'event', 'uid']);
    assert.equal(marker.get('uid'), ALICE.uid);
    assert.equal(marker.get('event'), 'opened');

    for (let repeat = 0; repeat < 3; repeat += 1) {
      assert.deepEqual(await track(ALICE, id, 'opened'), { counted: false });
    }
    assert.deepEqual(await counters(id), { opened: 1, actionTapped: 0 });

    assert.deepEqual(await track(MEHMET, id, 'opened'), { counted: true });
    assert.deepEqual(await counters(id), { opened: 2, actionTapped: 0 });
  });

  test('each event is deduped on its own', async () => {
    const id = await seedFanout([ALICE.uid]);

    assert.deepEqual(await track(ALICE, id, 'actionTapped'), { counted: true });
    assert.deepEqual(await counters(id), { opened: 0, actionTapped: 1 });
    assert.deepEqual(await track(ALICE, id, 'actionTapped'), { counted: false });

    assert.deepEqual(await track(ALICE, id, 'opened'), { counted: true });
    assert.deepEqual(await counters(id), { opened: 1, actionTapped: 1 });
  });

  test('the same user counts separately per notification', async () => {
    const first = await seedFanout([ALICE.uid]);
    const second = await seedBroadcast();
    await track(ALICE, first, 'opened');
    await track(ALICE, second, 'opened');
    assert.deepEqual(await counters(first), { opened: 1, actionTapped: 0 });
    assert.deepEqual(await counters(second), { opened: 1, actionTapped: 0 });
  });

  test('concurrent retries of one user count once', async () => {
    const id = await seedBroadcast();
    const results = await Promise.all(Array.from({ length: 12 }, () => track(ALICE, id, 'opened')));
    assert.equal(results.filter(({ counted }) => counted).length, 1);
    assert.equal(results.filter(({ counted }) => !counted).length, 11);
    assert.deepEqual(await counters(id), { opened: 1, actionTapped: 0 });
  });

  test('concurrent reports from different users all count', async () => {
    const users = Array.from({ length: 10 }, (_, index) => ({ uid: `reader-${index}`, phone: '+905550000000' }));
    const id = await seedFanout(users.map(({ uid }) => uid));
    const results = await Promise.all(users.flatMap((user) => [track(user, id, 'opened'), track(user, id, 'actionTapped')]));
    assert.ok(results.every(({ counted }) => counted));
    assert.deepEqual(await counters(id), { opened: 10, actionTapped: 10 });
  });

  test('a record without a stats map (or without these counters) still counts', async () => {
    const id = freshId();
    await notificationRef(id).set({ kind: 'general', title: 'Eski', body: 'Kayıt', delivery: 'fanout', status: 'sent' });
    await db.collection('users').doc(ALICE.uid).collection('inbox').doc(id).set({ title: 'x', body: 'y', createdAt: new Date() });

    assert.deepEqual(await track(ALICE, id, 'opened'), { counted: true });
    assert.equal((await notificationRef(id).get()).get('stats.opened'), 1);
  });

  test('the delivery counters next to it are left alone', async () => {
    const id = await seedFanout([ALICE.uid]);
    await notificationRef(id).update({ 'stats.pushSent': 5, 'stats.pushFailed': 1 });
    await track(ALICE, id, 'opened');
    const record = (await notificationRef(id).get()).get('stats');
    assert.deepEqual(record, { recipients: 1, pushTargets: 0, pushSent: 5, pushFailed: 1, opened: 1, actionTapped: 0 });
  });

  test('a notification removed between the check and the commit is not-found, not a crash', async () => {
    const id = await seedFanout([ALICE.uid]);
    // The record vanishes after the recipient check read it: simulated by deleting it from inside the inbox lookup.
    const racing = {
      collection: (name) => (name === 'notifications'
        ? {
          doc: (docId) => {
            const ref = db.collection('notifications').doc(docId);
            return new Proxy(ref, {
              get: (target, property) => (property === 'get'
                ? async () => {
                  const snapshot = await target.get();
                  await target.delete();
                  return snapshot;
                }
                : Reflect.get(target, property)),
            });
          },
        }
        : db.collection(name)),
      batch: () => db.batch(),
    };
    await assertHttpsError(
      stats.trackNotificationEventHandler({ db: racing }, asUser(ALICE, { notificationId: id, event: 'opened' })),
      'not-found'
    );
    assert.equal((await eventRef(id, ALICE.uid, 'opened').get()).exists, false);
  });
});

// --- Real deliveries ----------------------------------------------------------------------------------------------

describe('notifications delivered by sendNotification', () => {
  const PROFILE = {
    name: 'Ayşe', surname: 'Örnekoğlu', university: 'Ege Üniversitesi', universityId: 'ege-universitesi', universityIsCustom: false,
    faculty: 'Mühendislik Fakültesi', facultyId: 'muhendislik-fakultesi', facultyIsCustom: false,
    department: 'Bilgisayar Mühendisliği', departmentId: 'bilgisayar-muhendisligi', departmentIsCustom: false,
    gender: 'female', updatedAt: 1_700_000_000_000,
  };

  const messaging = {
    async send() { return 'projects/demo/messages/1'; },
    async sendEachForMulticast(message) {
      return { successCount: message.tokens.length, failureCount: 0, responses: message.tokens.map((token) => ({ success: true, messageId: token })) };
    },
  };

  const send = (data) => admin.sendNotificationHandler(
    { db, rtdb, messaging, now: () => DAY },
    { auth: { uid: ADMIN_UID, token: { admin: true } }, data }
  );

  beforeEach(async () => {
    await rtdb.ref('users').set({
      [ALICE.uid]: { profile: PROFILE },
      [MEHMET.uid]: { profile: { ...PROFILE, name: 'Mehmet', gender: 'male' } },
    });
  });

  test('a broadcast is countable by users who never got a copy of their own', async () => {
    const id = freshId();
    const sent = await send({ notificationId: id, kind: 'general', title: 'Duyuru', body: 'Herkese', audience: { scope: 'all' }, isTest: false });
    assert.equal(sent.status, 'sent');

    assert.deepEqual(await track(ALI, id, 'opened'), { counted: true });
    assert.deepEqual(await track(ALI, id, 'opened'), { counted: false });
    assert.deepEqual(await track(ALICE, id, 'actionTapped'), { counted: true });
    assert.deepEqual(await counters(id), { opened: 1, actionTapped: 1 });
    // The delivery stats written by the sender survive the increments.
    assert.equal((await notificationRef(id).get()).get('stats.recipients'), 2);
  });

  test('a segment fan-out is countable only by its recipients', async () => {
    const id = freshId();
    await send({
      notificationId: id, kind: 'general', title: 'Kadınlara', body: 'Mesaj', isTest: false,
      audience: { scope: 'segment', universityId: 'ege-universitesi', gender: 'female' },
    });

    assert.deepEqual(await track(ALICE, id, 'opened'), { counted: true });
    await assertHttpsError(track(MEHMET, id, 'opened'), 'not-found');
    assert.deepEqual(await counters(id), { opened: 1, actionTapped: 0 });
  });
});

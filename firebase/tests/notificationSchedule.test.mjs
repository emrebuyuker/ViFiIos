// Scheduled notifications (`functions/notifications/schedule.js`) against the Firestore and Realtime Database
// emulators: `cancelNotification` (admin gate, scheduled-only, not-found) and the `dispatchScheduledNotifications`
// job — due vs future, claim races between overlapping runs, expiry, quiet hours at dispatch time, failure isolation
// and the stuck-`sending` recovery (one retry, then failed). `now` is injected; FCM is a fake that records pushes.

import { test, before, after, beforeEach, describe, mock } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { PROJECT_ID, assertLocalEmulators } from './helpers.mjs';

// The functions' own firebase-admin, so snapshots and sentinels come from the same SDK as the code under test.
const requireFromFunctions = createRequire(new URL('../functions/package.json', import.meta.url));
const { getFirestore, Timestamp } = requireFromFunctions('firebase-admin/firestore');
const { getDatabaseWithUrl } = requireFromFunctions('firebase-admin/database');
const { getApp, deleteApp } = requireFromFunctions('firebase-admin/app');

const MINUTE = 60 * 1000;
const HOUR = 60 * MINUTE;
const DAY = new Date('2026-10-29T09:00:00Z'); // 12:00 in Türkiye
const LATE_EVENING = new Date('2026-10-29T19:05:00Z'); // 22:05 in Türkiye — quiet hours
const NEXT_MORNING = new Date('2026-10-30T06:00:00Z'); // 09:00 in Türkiye — quiet hours end

const ADMIN_UID = 'admin-1';
const EGE = 'ege-universitesi';
const MUHENDISLIK = 'muhendislik-fakultesi';
const BILGISAYAR = 'bilgisayar-muhendisligi';
const NOT_CANCELABLE = 'Bu bildirim gönderildiği için artık iptal edilemez.';

let db;
let rtdb;
let fns;
let admin;
let schedule;
let deliver;

before(async () => {
  assertLocalEmulators('FIRESTORE_EMULATOR_HOST', 'FIREBASE_DATABASE_EMULATOR_HOST');
  // Expected failures and run summaries are logged by the functions; keep the test output readable. (The logger
  // keeps the console methods it finds when first imported, so these mocks come before the imports.)
  mock.method(console, 'error', () => {});
  mock.method(console, 'warn', () => {});
  mock.method(console, 'info', () => {});
  fns = await import('../functions/index.js');
  admin = await import('../functions/notifications/admin.js');
  schedule = await import('../functions/notifications/schedule.js');
  deliver = await import('../functions/notifications/deliver.js');
  db = getFirestore('vifi');
  rtdb = getDatabaseWithUrl(`https://${PROJECT_ID}-default-rtdb.firebaseio.com`);
});

after(async () => {
  await deleteApp(getApp());
});

// --- Fixtures -----------------------------------------------------------------------------------------------------

function profile(universityId, facultyId, departmentId, gender, name) {
  return {
    name, surname: 'Örnekoğlu', university: 'Üniversite', universityId, universityIsCustom: false, faculty: 'Fakülte',
    facultyId, facultyIsCustom: false, department: 'Bölüm', departmentId, departmentIsCustom: false, gender,
    updatedAt: 1_700_000_000_000,
  };
}

const PROFILES = {
  ayse: profile(EGE, MUHENDISLIK, BILGISAYAR, 'female', 'Ayşe'),
  mehmet: profile(EGE, MUHENDISLIK, 'makine-muhendisligi', 'male', 'Mehmet'),
  ali: profile('bogazici-universitesi', 'fen-fakultesi', 'fizik', 'male', 'Ali'),
};
const DEVICES = { ayse: 'tok-ayse', mehmet: 'tok-mehmet', ali: 'tok-ali' };
const CONSENT = { ayse: true, mehmet: false, ali: true };
const ZERO_STATS = Object.freeze({ recipients: 0, pushTargets: 0, pushSent: 0, pushFailed: 0, opened: 0, actionTapped: 0 });

const notifications = () => db.collection('notifications');
const notificationDoc = (id) => notifications().doc(id).get();
const announcementDoc = (id) => db.collection('announcements').doc(id).get();

async function inboxOwners(id) {
  const owners = [];
  for (const uid of [...Object.keys(PROFILES), ADMIN_UID]) {
    if ((await db.collection('users').doc(uid).collection('inbox').doc(id).get()).exists) owners.push(uid);
  }
  return owners.sort();
}

async function clearFirestore() {
  const host = process.env.FIRESTORE_EMULATOR_HOST;
  const response = await fetch(`http://${host}/emulator/v1/projects/${PROJECT_ID}/databases/vifi/documents`, { method: 'DELETE' });
  assert.ok(response.ok, `clearing the Firestore emulator failed: ${response.status}`);
}

beforeEach(async () => {
  await clearFirestore();
  await rtdb.ref('users').set(Object.fromEntries(Object.entries(PROFILES).map(([uid, value]) => [uid, { profile: value }])));
  const writer = db.bulkWriter();
  for (const [uid, token] of Object.entries(DEVICES)) {
    writer.set(db.collection('users').doc(uid).collection('devices').doc(`d-${uid}`), {
      token, platform: 'ios', appVersion: '4.1.0', updatedAt: new Date(),
    });
  }
  for (const [uid, marketing] of Object.entries(CONSENT)) {
    writer.set(db.collection('users').doc(uid).collection('settings').doc('notifications'), {
      marketing, source: 'prompt', version: 1, updatedAt: new Date(),
    });
  }
  await writer.close();
});

/** A fake FCM client that records every push. */
function fakeMessaging() {
  const fake = {
    topicMessages: [],
    multicasts: [],
    async send(message) {
      fake.topicMessages.push(message);
      return `projects/${PROJECT_ID}/messages/1`;
    },
    async sendEachForMulticast(message) {
      fake.multicasts.push(message);
      const responses = message.tokens.map((token) => ({ success: true, messageId: `m-${token}` }));
      return { successCount: responses.length, failureCount: 0, responses };
    },
  };
  /** The notification ids pushed, one entry per push call. */
  fake.pushedIds = () => [...fake.topicMessages, ...fake.multicasts].map(({ data }) => data.notificationId).sort();
  return fake;
}

function depsWith(messaging, now, extra = {}) {
  return { db, rtdb, messaging, signImageUrl: async () => null, now: () => now, ...extra };
}

const dispatch = (deps) => schedule.dispatchScheduledNotificationsHandler(deps);
const asAdmin = (data, uid = ADMIN_UID) => ({ auth: { uid, token: { admin: true } }, data });

let sequence = 0;
const freshId = () => `s-${process.pid}-${++sequence}`;

function draft(overrides = {}) {
  return { notificationId: freshId(), kind: 'general', title: 'Başlık', body: 'Mesaj', audience: { scope: 'all' }, isTest: false, ...overrides };
}

/** Composes a notification through `sendNotification` at `DAY`, scheduled `after` later. */
async function composeScheduled(after, overrides = {}) {
  const request = draft({ scheduledAt: DAY.getTime() + after, ...overrides });
  const result = await admin.sendNotificationHandler(depsWith(fakeMessaging(), DAY), asAdmin(request));
  assert.equal(result.status, 'scheduled');
  return request.notificationId;
}

/** Writes a stored notification directly (as `sendNotification` or the automatic notifications would). */
async function seed(id, fields) {
  await notifications().doc(id).set({
    kind: 'general', title: 'Başlık', body: 'Mesaj', audience: { scope: 'all' }, audienceLabel: 'Tüm kullanıcılar',
    delivery: 'broadcast', status: 'scheduled', isTest: false, scheduledAt: null, deferredByQuietHours: false,
    expiresAt: null, source: 'admin', createdBy: ADMIN_UID, createdAt: DAY, stats: { ...ZERO_STATS }, ...fields,
  });
}

async function assertHttpsError(promise, code, message) {
  await assert.rejects(promise, (error) => {
    assert.equal(error.code, code);
    if (message) assert.equal(error.message, message);
    return true;
  });
}

const summaryWith = (counts) => ({ sent: 0, failed: 0, expired: 0, deferred: 0, skipped: 0, retried: 0, gaveUp: 0, errors: 0, ...counts });

// --- cancelNotification -------------------------------------------------------------------------------------------

describe('cancelNotification', () => {
  test('refuses callers without a strict admin: true claim', async () => {
    const id = await composeScheduled(HOUR);
    const requests = [
      { data: { notificationId: id } },
      { auth: { uid: 'u1', token: {} }, data: { notificationId: id } },
      { auth: { uid: 'u2', token: { admin: 'true' } }, data: { notificationId: id } },
    ];
    for (const request of requests) {
      await assertHttpsError(fns.cancelNotification.run(request), 'permission-denied', 'Bu işlem için yetkin yok.');
    }
    assert.equal((await notificationDoc(id)).get('status'), 'scheduled');
  });

  test('cancels a scheduled notification with who and when; the dispatcher never sends it', async () => {
    const id = await composeScheduled(HOUR);
    const result = await fns.cancelNotification.run(asAdmin({ notificationId: id }, 'admin-2'));
    assert.deepEqual(result, { notificationId: id, status: 'canceled' });

    const stored = (await notificationDoc(id)).data();
    assert.equal(stored.status, 'canceled');
    assert.equal(stored.canceledBy, 'admin-2');
    assert.ok(stored.canceledAt instanceof Timestamp);
    assert.equal('error' in stored, false);

    const messaging = fakeMessaging();
    assert.deepEqual(await dispatch(depsWith(messaging, new Date(DAY.getTime() + 2 * HOUR))), summaryWith({}));
    assert.deepEqual(messaging.pushedIds(), []);
    assert.equal((await announcementDoc(id)).exists, false);
    assert.equal((await notificationDoc(id)).get('status'), 'canceled');
  });

  test('anything but scheduled is failed-precondition and left as it was', async () => {
    for (const status of ['sending', 'sent', 'failed']) {
      await seed(`c-${status}`, { status });
      await assertHttpsError(
        schedule.cancelNotificationHandler(depsWith(fakeMessaging(), DAY), asAdmin({ notificationId: `c-${status}` })),
        'failed-precondition',
        NOT_CANCELABLE
      );
      assert.equal((await notificationDoc(`c-${status}`)).get('status'), status);
    }

    // A second cancel (e.g. a retried tap) is refused too; the first cancel's record stays.
    const id = await composeScheduled(HOUR);
    await schedule.cancelNotificationHandler(depsWith(fakeMessaging(), DAY), asAdmin({ notificationId: id }));
    await assertHttpsError(
      schedule.cancelNotificationHandler(depsWith(fakeMessaging(), DAY), asAdmin({ notificationId: id }, 'admin-2')),
      'failed-precondition'
    );
    assert.equal((await notificationDoc(id)).get('canceledBy'), ADMIN_UID);
  });

  test('an unknown id is not-found; a missing or malformed id is invalid-argument', async () => {
    const deps = depsWith(fakeMessaging(), DAY);
    await assertHttpsError(schedule.cancelNotificationHandler(deps, asAdmin({ notificationId: 'nope' })), 'not-found', 'Bildirim bulunamadı.');
    for (const data of [{}, { notificationId: '' }, { notificationId: 'a/b' }, { notificationId: 42 }, null]) {
      await assertHttpsError(schedule.cancelNotificationHandler(deps, asAdmin(data)), 'invalid-argument', 'Geçersiz bildirim kimliği.');
    }
  });

  test('a cancel racing the dispatcher: exactly one of them wins', async () => {
    const id = await composeScheduled(HOUR);
    const messaging = fakeMessaging();
    const [canceled, summary] = await Promise.allSettled([
      schedule.cancelNotificationHandler(depsWith(messaging, DAY), asAdmin({ notificationId: id })),
      dispatch(depsWith(messaging, new Date(DAY.getTime() + HOUR))),
    ]);
    const status = (await notificationDoc(id)).get('status');
    assert.equal(summary.status, 'fulfilled');
    if (canceled.status === 'fulfilled') {
      assert.equal(status, 'canceled');
      assert.deepEqual(messaging.pushedIds(), []);
      assert.equal(summary.value.sent, 0);
    } else {
      assert.equal(canceled.reason.code, 'failed-precondition');
      assert.equal(status, 'sent');
      assert.deepEqual(messaging.pushedIds(), [id]);
    }
  });
});

// --- dispatchScheduledNotifications -------------------------------------------------------------------------------

describe('dispatchScheduledNotifications', () => {
  test('is wired to run every 5 minutes on Türkiye time in europe-west1', () => {
    const endpoint = fns.dispatchScheduledNotifications.__endpoint;
    assert.equal(endpoint.scheduleTrigger.schedule, '*/5 * * * *');
    assert.equal(endpoint.scheduleTrigger.timeZone, 'Europe/Istanbul');
    assert.deepEqual(endpoint.region, ['europe-west1']);
    assert.deepEqual(fns.cancelNotification.__endpoint.region, ['europe-west1']);
  });

  test('delivers the due notifications only; a future one keeps waiting for its run', async () => {
    const broadcast = await composeScheduled(HOUR);
    const segment = await composeScheduled(HOUR, { audience: { scope: 'segment', universityId: EGE, facultyId: MUHENDISLIK } });
    const later = await composeScheduled(3 * HOUR);
    const firstRun = new Date(DAY.getTime() + HOUR + 2 * MINUTE);

    const messaging = fakeMessaging();
    assert.deepEqual(await dispatch(depsWith(messaging, firstRun)), summaryWith({ sent: 2 }));
    assert.deepEqual(messaging.pushedIds(), [broadcast, segment].sort());

    assert.equal((await announcementDoc(broadcast)).exists, true);
    assert.deepEqual(await inboxOwners(segment), ['ayse', 'mehmet']);
    for (const id of [broadcast, segment]) {
      const stored = (await notificationDoc(id)).data();
      assert.equal(stored.status, 'sent');
      assert.equal(stored.deliveryAttempts, 1);
      assert.equal(stored.sendingAt.toMillis(), firstRun.getTime());
      assert.ok(stored.sentAt instanceof Timestamp);
    }
    assert.equal((await notificationDoc(segment)).get('stats.recipients'), 2);

    const waiting = (await notificationDoc(later)).data();
    assert.equal(waiting.status, 'scheduled');
    assert.equal('sendingAt' in waiting, false);

    // The next run finds nothing new until the later one is due.
    const idle = fakeMessaging();
    assert.deepEqual(await dispatch(depsWith(idle, new Date(firstRun.getTime() + 5 * MINUTE))), summaryWith({}));
    assert.deepEqual(idle.pushedIds(), []);

    const lastRun = fakeMessaging();
    assert.deepEqual(await dispatch(depsWith(lastRun, new Date(DAY.getTime() + 3 * HOUR))), summaryWith({ sent: 1 }));
    assert.deepEqual(lastRun.pushedIds(), [later]);
  });

  test('two overlapping runs deliver each notification once', async () => {
    const ids = [];
    for (let index = 0; index < 4; index += 1) ids.push(await composeScheduled(HOUR + index * MINUTE));
    const messaging = fakeMessaging();
    const runAt = new Date(DAY.getTime() + 2 * HOUR);

    const [first, second] = await Promise.all([dispatch(depsWith(messaging, runAt)), dispatch(depsWith(messaging, runAt))]);
    // Each run either claims a notification or finds it already taken (skipped, or gone from its query).
    assert.equal(first.sent + second.sent, 4);
    assert.equal(first.errors + second.errors, 0);
    assert.deepEqual(messaging.pushedIds(), [...ids].sort());
    for (const id of ids) assert.equal((await notificationDoc(id)).get('status'), 'sent');
  });

  test('a notification that expired before it could go out is canceled as expired, never delivered', async () => {
    await seed('expired-1', { scheduledAt: new Date(DAY.getTime() - 2 * HOUR), expiresAt: new Date(DAY.getTime() - HOUR) });
    await seed('expires-now', { scheduledAt: new Date(DAY.getTime() - HOUR), expiresAt: DAY });
    const messaging = fakeMessaging();

    assert.deepEqual(await dispatch(depsWith(messaging, DAY)), summaryWith({ expired: 2 }));
    assert.deepEqual(messaging.pushedIds(), []);
    for (const id of ['expired-1', 'expires-now']) {
      const stored = (await notificationDoc(id)).data();
      assert.equal(stored.status, 'canceled');
      assert.equal(stored.error, 'expired');
      assert.equal(stored.canceledBy, 'system');
      assert.ok(stored.canceledAt instanceof Timestamp);
      assert.equal((await announcementDoc(id)).exists, false);
    }
  });

  test('an unexpired notification goes out with its expiry on the inbox copy', async () => {
    const expiresAt = new Date(DAY.getTime() + 5 * HOUR);
    await seed('valid-1', { scheduledAt: new Date(DAY.getTime() - MINUTE), expiresAt });
    assert.deepEqual(await dispatch(depsWith(fakeMessaging(), DAY)), summaryWith({ sent: 1 }));
    assert.equal((await announcementDoc('valid-1')).get('expiresAt').toMillis(), expiresAt.getTime());
  });

  test('quiet hours at dispatch time: campaigns and automatic "new exam" notices wait for 09:00, others go', async () => {
    // Due at 21:50 but dispatched at 22:05 (a late run): the campaign and the automatic notice must wait.
    const dueAt = new Date(LATE_EVENING.getTime() - 15 * MINUTE);
    await seed('promo-1', { kind: 'promo', delivery: 'fanout', scheduledAt: dueAt });
    await seed('new-exam-1', {
      kind: 'general', delivery: 'fanout', source: 'automatic', trigger: 'newExam', createdBy: 'system', scheduledAt: dueAt,
      audience: { scope: 'segment', universityId: EGE, facultyId: MUHENDISLIK, departmentId: BILGISAYAR },
    });
    await seed('promo-short', { kind: 'promo', delivery: 'fanout', scheduledAt: dueAt, expiresAt: new Date(LATE_EVENING.getTime() + HOUR) });
    await seed('general-1', { scheduledAt: dueAt });

    const night = fakeMessaging();
    assert.deepEqual(await dispatch(depsWith(night, LATE_EVENING)), summaryWith({ sent: 1, deferred: 2, expired: 1 }));
    assert.deepEqual(night.pushedIds(), ['general-1']);
    for (const id of ['promo-1', 'new-exam-1']) {
      const stored = (await notificationDoc(id)).data();
      assert.equal(stored.status, 'scheduled');
      assert.equal(stored.deferredByQuietHours, true);
      assert.equal(stored.scheduledAt.toMillis(), NEXT_MORNING.getTime());
    }
    const short = (await notificationDoc('promo-short')).data();
    assert.equal(short.status, 'canceled');
    assert.equal(short.error, 'expired');

    // Still quiet just before 09:00: not due yet, nothing moves.
    const dawn = fakeMessaging();
    assert.deepEqual(await dispatch(depsWith(dawn, new Date(NEXT_MORNING.getTime() - 5 * MINUTE))), summaryWith({}));
    assert.deepEqual(dawn.pushedIds(), []);

    const morning = fakeMessaging();
    assert.deepEqual(await dispatch(depsWith(morning, NEXT_MORNING)), summaryWith({ sent: 2 }));
    assert.deepEqual(morning.pushedIds(), ['new-exam-1', 'promo-1']);
    // The campaign reaches only users who opted in; the department notice only its members.
    assert.deepEqual(await inboxOwners('promo-1'), ['ali', 'ayse']);
    assert.deepEqual(await inboxOwners('new-exam-1'), ['ayse']);
  });

  test('one failing notification never stops the others', async () => {
    const dueAt = new Date(DAY.getTime() - MINUTE);
    // Delivery fails inside deliverNotification (a personal notice without its user) → `failed`.
    await seed('bad-audience', { kind: 'system', delivery: 'fanout', audience: { scope: 'user' }, scheduledAt: dueAt });
    // Delivery throws outright (simulated crash after the claim) → stays `sending` for the recovery.
    await seed('crashes', { scheduledAt: dueAt });
    await seed('good-1', { scheduledAt: dueAt });
    await seed('good-2', { delivery: 'fanout', audience: { scope: 'segment', universityId: EGE }, scheduledAt: dueAt });

    const messaging = fakeMessaging();
    const crashing = async (deps, id) => {
      if (id === 'crashes') throw new Error('instance went away');
      return deliver.deliverNotification(deps, id);
    };
    const summary = await dispatch(depsWith(messaging, DAY, { deliver: crashing }));
    assert.deepEqual(summary, summaryWith({ sent: 2, failed: 1, errors: 1 }));
    assert.deepEqual(messaging.pushedIds(), ['good-1', 'good-2']);
    assert.equal((await notificationDoc('good-1')).get('status'), 'sent');
    assert.equal((await notificationDoc('good-2')).get('status'), 'sent');
    const bad = (await notificationDoc('bad-audience')).data();
    assert.equal(bad.status, 'failed');
    assert.match(bad.error, /uid/);
    assert.equal((await notificationDoc('crashes')).get('status'), 'sending');
  });

  test('handles at most one batch per run, oldest first', async () => {
    const total = schedule.DISPATCH_BATCH + 2;
    const batchId = (index) => `batch-${String(index).padStart(3, '0')}`;
    const writer = db.bulkWriter();
    for (let index = 0; index < total; index += 1) {
      writer.set(notifications().doc(batchId(index)), {
        kind: 'general', title: 'T', body: 'B', audience: { scope: 'user', uid: 'ayse' }, delivery: 'fanout',
        status: 'scheduled', isTest: false, scheduledAt: new Date(DAY.getTime() - (total - index) * MINUTE),
        expiresAt: null, createdAt: DAY, stats: { ...ZERO_STATS },
      });
    }
    await writer.close();

    const messaging = fakeMessaging();
    assert.equal((await dispatch(depsWith(messaging, DAY))).sent, schedule.DISPATCH_BATCH);
    const waiting = await notifications().where('status', '==', 'scheduled').get();
    assert.deepEqual(waiting.docs.map(({ id }) => id).sort(), [batchId(total - 2), batchId(total - 1)]);
    assert.equal((await dispatch(depsWith(messaging, DAY))).sent, 2);
  });
});

// --- Stuck `sending` recovery -------------------------------------------------------------------------------------

describe('stuck delivery recovery', () => {
  // The module loads in `before`, after this suite body runs, so its constants are read lazily.
  const stuckFor = () => schedule.STUCK_SENDING_AFTER_MS + MINUTE;
  const stuckSince = (now) => new Date(now.getTime() - stuckFor());
  const segmentAudience = { scope: 'segment', universityId: EGE, facultyId: MUHENDISLIK };

  test('a delivery stuck in sending is retried once; inbox copies are rewritten, not duplicated', async () => {
    await seed('stuck-1', { status: 'sending', delivery: 'fanout', audience: segmentAudience, sendingAt: stuckSince(DAY), deliveryAttempts: 1 });
    // The crashed attempt had already reached Ayşe.
    await db.collection('users').doc('ayse').collection('inbox').doc('stuck-1')
      .set({ kind: 'general', title: 'Başlık', body: 'Mesaj', createdAt: stuckSince(DAY) });

    const messaging = fakeMessaging();
    assert.deepEqual(await dispatch(depsWith(messaging, DAY)), summaryWith({ retried: 1, sent: 1 }));
    assert.deepEqual(messaging.pushedIds(), ['stuck-1']);
    assert.deepEqual(await inboxOwners('stuck-1'), ['ayse', 'mehmet']);
    assert.equal((await db.collection('users').doc('ayse').collection('inbox').get()).size, 1);

    const stored = (await notificationDoc('stuck-1')).data();
    assert.equal(stored.status, 'sent');
    assert.equal(stored.deliveryAttempts, 2);
    assert.equal(stored.sendingAt.toMillis(), DAY.getTime());
    assert.equal(stored.stats.recipients, 2);
  });

  test('a "send now" notification without sendingAt is aged by its createdAt', async () => {
    await seed('legacy-1', { status: 'sending', createdAt: stuckSince(DAY) });
    const messaging = fakeMessaging();
    assert.deepEqual(await dispatch(depsWith(messaging, DAY)), summaryWith({ retried: 1, sent: 1 }));
    assert.deepEqual(messaging.pushedIds(), ['legacy-1']);
    assert.equal((await notificationDoc('legacy-1')).get('deliveryAttempts'), 2);
  });

  test('a delivery still in flight, or of unknown age, is left alone', async () => {
    await seed('in-flight', { status: 'sending', sendingAt: new Date(DAY.getTime() - 5 * MINUTE), deliveryAttempts: 1 });
    await seed('just-created', { status: 'sending', createdAt: new Date(DAY.getTime() - 2 * MINUTE) });
    await seed('no-age', { status: 'sending', createdAt: null });

    const messaging = fakeMessaging();
    assert.deepEqual(await dispatch(depsWith(messaging, DAY)), summaryWith({}));
    assert.deepEqual(messaging.pushedIds(), []);
    for (const id of ['in-flight', 'just-created', 'no-age']) assert.equal((await notificationDoc(id)).get('status'), 'sending');
  });

  test('gives up after the retry: the notification ends as failed', async () => {
    await seed('stuck-twice', { status: 'sending', sendingAt: stuckSince(DAY), deliveryAttempts: 2 });
    const messaging = fakeMessaging();
    assert.deepEqual(await dispatch(depsWith(messaging, DAY)), summaryWith({ gaveUp: 1 }));
    assert.deepEqual(messaging.pushedIds(), []);
    const stored = (await notificationDoc('stuck-twice')).data();
    assert.equal(stored.status, 'failed');
    assert.equal(stored.error, schedule.STUCK_ERROR);
  });

  test('a stuck notification that has expired meanwhile is failed, not retried', async () => {
    await seed('stuck-expired', { status: 'sending', sendingAt: stuckSince(DAY), deliveryAttempts: 1, expiresAt: new Date(DAY.getTime() - MINUTE) });
    const messaging = fakeMessaging();
    assert.deepEqual(await dispatch(depsWith(messaging, DAY)), summaryWith({ gaveUp: 1 }));
    assert.deepEqual(messaging.pushedIds(), []);
    const stored = (await notificationDoc('stuck-expired')).data();
    assert.equal(stored.status, 'failed');
    assert.equal(stored.error, schedule.STUCK_EXPIRED_ERROR);
  });

  test('a retry that crashes again is given up by a later run, once it is stuck again', async () => {
    const dueAt = new Date(DAY.getTime() - MINUTE);
    await seed('flaky', { scheduledAt: dueAt });
    const crash = async () => {
      throw new Error('instance went away');
    };

    // Run 1 claims it and crashes; run 2 (16 minutes later) retries it and crashes again.
    assert.deepEqual(await dispatch(depsWith(fakeMessaging(), DAY, { deliver: crash })), summaryWith({ errors: 1 }));
    const retryAt = new Date(DAY.getTime() + stuckFor());
    assert.deepEqual(await dispatch(depsWith(fakeMessaging(), retryAt, { deliver: crash })), summaryWith({ retried: 1, errors: 1 }));
    let stored = (await notificationDoc('flaky')).data();
    assert.equal(stored.status, 'sending');
    assert.equal(stored.deliveryAttempts, 2);
    assert.equal(stored.sendingAt.toMillis(), retryAt.getTime());

    // Run 3 shortly after leaves the fresh retry alone; run 4, once it is stuck again, gives up.
    const messaging = fakeMessaging();
    assert.deepEqual(await dispatch(depsWith(messaging, new Date(retryAt.getTime() + 5 * MINUTE))), summaryWith({}));
    assert.deepEqual(await dispatch(depsWith(messaging, new Date(retryAt.getTime() + stuckFor()))), summaryWith({ gaveUp: 1 }));
    assert.deepEqual(messaging.pushedIds(), []);
    stored = (await notificationDoc('flaky')).data();
    assert.equal(stored.status, 'failed');
    assert.equal(stored.error, schedule.STUCK_ERROR);
  });

  test('two overlapping runs retry a stuck delivery once', async () => {
    await seed('stuck-race', { status: 'sending', sendingAt: stuckSince(DAY), deliveryAttempts: 1 });
    const messaging = fakeMessaging();
    const [first, second] = await Promise.all([dispatch(depsWith(messaging, DAY)), dispatch(depsWith(messaging, DAY))]);
    assert.equal(first.retried + second.retried, 1);
    assert.equal(first.sent + second.sent, 1);
    assert.deepEqual(messaging.pushedIds(), ['stuck-race']);
    assert.equal((await notificationDoc('stuck-race')).get('deliveryAttempts'), 2);
  });
});

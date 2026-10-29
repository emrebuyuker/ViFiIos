// The targeted-notification Cloud Functions (`functions/notifications/`) against the Firestore and Realtime Database
// emulators: the admin gate, input validation, idempotency, broadcast vs fan-out delivery, segment resolution,
// campaign consent, test sends, the exam action, scheduling / quiet hours, token pruning, stats and the device-token
// dedupe trigger. FCM is a fake that records what would have been pushed; nothing leaves this machine.

import { test, before, after, beforeEach, describe, mock } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { PROJECT_ID, assertLocalEmulators } from './helpers.mjs';

// The functions' own firebase-admin (not the test tooling's newer copy), so FieldValue sentinels, snapshots and these
// database handles all come from the same SDK instance as the code under test.
const requireFromFunctions = createRequire(new URL('../functions/package.json', import.meta.url));
const { getFirestore, Timestamp } = requireFromFunctions('firebase-admin/firestore');
const { getDatabaseWithUrl } = requireFromFunctions('firebase-admin/database');
const { getApp, deleteApp } = requireFromFunctions('firebase-admin/app');

const DAY = new Date('2026-10-29T09:00:00Z'); // 12:00 in Türkiye
const NIGHT = new Date('2026-10-29T20:00:00Z'); // 23:00 in Türkiye
const NEXT_MORNING = new Date('2026-10-30T06:00:00Z'); // 09:00 in Türkiye

const ADMIN_UID = 'admin-1';
const EGE = 'ege-universitesi';
const MUHENDISLIK = 'muhendislik-fakultesi';
const BILGISAYAR = 'bilgisayar-muhendisligi';

let db;
let rtdb;
let fns;
let admin;
let deliver;
let devices;

before(async () => {
  assertLocalEmulators('FIRESTORE_EMULATOR_HOST', 'FIREBASE_DATABASE_EMULATOR_HOST');
  // Expected failures are logged by the functions; keep the test output readable.
  mock.method(console, 'error', () => {});
  mock.method(console, 'warn', () => {});
  fns = await import('../functions/index.js');
  admin = await import('../functions/notifications/admin.js');
  deliver = await import('../functions/notifications/deliver.js');
  devices = await import('../functions/notifications/devices.js');
  db = getFirestore('vifi');
  rtdb = getDatabaseWithUrl(`https://${PROJECT_ID}-default-rtdb.firebaseio.com`);
});

after(async () => {
  await deleteApp(getApp());
});

// --- Fixtures -----------------------------------------------------------------------------------------------------

function profile(university, universityId, faculty, facultyId, department, departmentId, gender, name) {
  return {
    name, surname: 'Örnekoğlu', university, universityId, universityIsCustom: false, faculty, facultyId,
    facultyIsCustom: false, department, departmentId, departmentIsCustom: false, gender, updatedAt: 1_700_000_000_000,
  };
}

const PROFILES = {
  ayse: profile('Ege Üniversitesi', EGE, 'Mühendislik Fakültesi', MUHENDISLIK, 'Bilgisayar Mühendisliği', BILGISAYAR, 'female', 'Ayşe'),
  mehmet: profile('Ege Üniversitesi', EGE, 'Mühendislik Fakültesi', MUHENDISLIK, 'Makine Mühendisliği', 'makine-muhendisligi', 'male', 'Mehmet'),
  zeynep: profile('Ege Üniversitesi', EGE, 'Tıp Fakültesi', 'tip-fakultesi', 'Tıp', 'tip', 'female', 'Zeynep'),
  ali: profile('Boğaziçi Üniversitesi', 'bogazici-universitesi', 'Fen Fakültesi', 'fen-fakultesi', 'Fizik', 'fizik', 'male', 'Ali'),
};

const DEVICES = {
  ayse: { 'd-ayse': 'tok-ayse' },
  mehmet: { 'd-mehmet-1': 'tok-mehmet-1', 'd-mehmet-2': 'tok-mehmet-2' },
  ali: { 'd-ali': 'tok-ali' },
  [ADMIN_UID]: { 'd-admin': 'tok-admin' },
};

const CONSENT = { ayse: true, mehmet: false, ali: true };

const deviceRef = (uid, deviceId) => db.collection('users').doc(uid).collection('devices').doc(deviceId);
const inboxDoc = (uid, id) => db.collection('users').doc(uid).collection('inbox').doc(id).get();
const notificationDoc = (id) => db.collection('notifications').doc(id).get();

async function clearFirestore() {
  const host = process.env.FIRESTORE_EMULATOR_HOST;
  const response = await fetch(`http://${host}/emulator/v1/projects/${PROJECT_ID}/databases/vifi/documents`, { method: 'DELETE' });
  assert.ok(response.ok, `clearing the Firestore emulator failed: ${response.status}`);
}

async function addDevice(uid, deviceId, token) {
  await deviceRef(uid, deviceId).set({ token, platform: 'ios', appVersion: '4.1.0', updatedAt: new Date() });
}

beforeEach(async () => {
  await clearFirestore();
  await rtdb.ref('users').set(Object.fromEntries(Object.entries(PROFILES).map(([uid, value]) => [uid, { profile: value }])));
  const writer = db.bulkWriter();
  for (const [uid, list] of Object.entries(DEVICES)) {
    for (const [deviceId, token] of Object.entries(list)) {
      writer.set(deviceRef(uid, deviceId), { token, platform: 'ios', appVersion: '4.1.0', updatedAt: new Date() });
    }
  }
  for (const [uid, marketing] of Object.entries(CONSENT)) {
    writer.set(db.collection('users').doc(uid).collection('settings').doc('notifications'), {
      marketing, source: 'prompt', version: 1, updatedAt: new Date(),
    });
  }
  await writer.close();
});

/** A fake FCM client: records every push; `failures` maps a token to the error code FCM reports for it. */
function fakeMessaging({ failures = {}, topicError = null } = {}) {
  const fake = {
    topicMessages: [],
    multicasts: [],
    async send(message) {
      if (topicError) throw Object.assign(new Error(topicError), { code: 'messaging/internal-error' });
      fake.topicMessages.push(message);
      return `projects/${PROJECT_ID}/messages/1`;
    },
    async sendEachForMulticast(message) {
      fake.multicasts.push(message);
      const responses = message.tokens.map((token) => (failures[token]
        ? { success: false, error: { code: failures[token], message: 'refused' } }
        : { success: true, messageId: `m-${token}` }));
      const successCount = responses.filter(({ success }) => success).length;
      return { successCount, failureCount: responses.length - successCount, responses };
    },
  };
  return fake;
}

function depsWith(messaging = fakeMessaging(), now = DAY) {
  return { db, rtdb, messaging, now: () => now };
}

let sequence = 0;
const freshId = () => `n-${process.pid}-${++sequence}`;

const asAdmin = (data, uid = ADMIN_UID) => ({ auth: { uid, token: { admin: true } }, data });

function draft(overrides = {}) {
  return { notificationId: freshId(), kind: 'general', title: 'Başlık', body: 'Mesaj', audience: { scope: 'all' }, isTest: false, ...overrides };
}

const segment = (fields) => ({ scope: 'segment', universityId: EGE, ...fields });

async function assertHttpsError(promise, code, message) {
  await assert.rejects(promise, (error) => {
    assert.equal(error.code, code);
    if (message) assert.equal(error.message, message);
    return true;
  });
}

async function inboxOwners(id) {
  const owners = [];
  for (const uid of [...Object.keys(PROFILES), ADMIN_UID]) {
    if ((await inboxDoc(uid, id)).exists) owners.push(uid);
  }
  return owners.sort();
}

// --- Admin gate and validation ------------------------------------------------------------------------------------

describe('admin gate and validation', () => {
  test('every admin callable refuses callers without a strict admin: true claim', async () => {
    const requests = [
      { data: {} },
      { auth: { uid: 'u1', token: {} }, data: {} },
      { auth: { uid: 'u2', token: { admin: 'true' } }, data: {} },
    ];
    for (const callable of [fns.getNotificationAudience, fns.previewNotification, fns.sendNotification]) {
      for (const request of requests) {
        await assertHttpsError(callable.run(request), 'permission-denied', 'Bu işlem için yetkin yok.');
      }
    }
  });

  test('schema errors become invalid-argument with the Turkish message, and nothing is written', async () => {
    const deps = depsWith();
    const request = draft({ title: '   ' });
    await assertHttpsError(admin.sendNotificationHandler(deps, asAdmin(request)), 'invalid-argument', 'Başlık boş olamaz.');
    await assertHttpsError(
      admin.sendNotificationHandler(deps, asAdmin(draft({ audience: { scope: 'segment', departmentId: BILGISAYAR } }))),
      'invalid-argument',
      'Geçerli bir hedef kitle seç.'
    );
    await assertHttpsError(admin.sendNotificationHandler(deps, asAdmin(draft({ kind: 'system' }))), 'invalid-argument', 'Geçersiz bildirim türü.');
    await assertHttpsError(
      admin.sendNotificationHandler(deps, asAdmin(draft({ scheduledAt: DAY.getTime() - 10 * 60 * 1000 }))),
      'invalid-argument',
      'Gönderim zamanı geçmişte olamaz.'
    );
    assert.equal((await notificationDoc(request.notificationId)).exists, false);
  });

  test('preview validates its kind and audience too', async () => {
    const deps = depsWith();
    await assertHttpsError(admin.previewNotificationHandler(deps, asAdmin({ kind: 'system', audience: { scope: 'all' } })), 'invalid-argument');
    await assertHttpsError(
      admin.previewNotificationHandler(deps, asAdmin({ kind: 'general', audience: { scope: 'user', uid: 'ayse' } })),
      'invalid-argument',
      'Geçerli bir hedef kitle seç.'
    );
  });

  test('an image is refused until phase 2', async () => {
    const request = draft();
    request.imagePath = `notificationImages/${request.notificationId}.jpg`;
    await assertHttpsError(admin.sendNotificationHandler(depsWith(), asAdmin(request)), 'failed-precondition', 'Görsel henüz desteklenmiyor.');
    assert.equal((await notificationDoc(request.notificationId)).exists, false);
  });
});

// --- Audience and preview -----------------------------------------------------------------------------------------

describe('audience and preview', () => {
  test('the audience tree has names and per-gender counts only — no personal data', async () => {
    const facets = await admin.getNotificationAudienceHandler(depsWith(), asAdmin({}));
    assert.equal(facets.total, 4);
    assert.deepEqual(facets.universities.map(({ id, name, count, female, male }) => ({ id, name, count, female, male })), [
      { id: 'bogazici-universitesi', name: 'Boğaziçi Üniversitesi', count: 1, female: 0, male: 1 },
      { id: EGE, name: 'Ege Üniversitesi', count: 3, female: 2, male: 1 },
    ]);
    const ege = facets.universities[1];
    assert.deepEqual(ege.faculties.map(({ id, count }) => [id, count]), [[MUHENDISLIK, 2], ['tip-fakultesi', 1]]);
    assert.deepEqual(ege.faculties[0].departments.map(({ id, count }) => [id, count]), [[BILGISAYAR, 1], ['makine-muhendisligi', 1]]);
    const json = JSON.stringify(facets);
    for (const personal of ['Ayşe', 'Mehmet', 'Örnekoğlu', 'ayse', 'mehmet']) assert.ok(!json.includes(personal), personal);
  });

  test('segments resolve by university, then faculty, department and gender', async () => {
    const preview = (kind, audience) => admin.previewNotificationHandler(depsWith(), asAdmin({ kind, audience }));
    assert.deepEqual(await preview('general', segment({})), { recipients: 3, pushTargets: 3 });
    assert.deepEqual(await preview('general', segment({ facultyId: MUHENDISLIK })), { recipients: 2, pushTargets: 3 });
    assert.deepEqual(await preview('general', segment({ facultyId: MUHENDISLIK, departmentId: BILGISAYAR })), { recipients: 1, pushTargets: 1 });
    assert.deepEqual(await preview('general', segment({ gender: 'female' })), { recipients: 2, pushTargets: 1 });
    assert.deepEqual(await preview('general', segment({ gender: 'male' })), { recipients: 1, pushTargets: 2 });
    assert.deepEqual(await preview('general', { scope: 'segment', universityId: 'yok-universitesi' }), { recipients: 0, pushTargets: 0 });
  });

  test('a general "everyone" previews the broadcast; campaigns count only users who opted in', async () => {
    const preview = (kind, audience) => admin.previewNotificationHandler(depsWith(), asAdmin({ kind, audience }));
    // Every profile; every registered device (the admin's included — the topic reaches every install).
    assert.deepEqual(await preview('general', { scope: 'all' }), { recipients: 4, pushTargets: 5 });
    assert.deepEqual(await preview('promo', { scope: 'all' }), { recipients: 2, pushTargets: 2 }); // ayse + ali
    assert.deepEqual(await preview('promo', segment({})), { recipients: 1, pushTargets: 1 }); // ayse only
  });
});

// --- Sending ------------------------------------------------------------------------------------------------------

describe('sendNotification', () => {
  test('a general "everyone" broadcasts: one announcement + the all topic, no inbox copies', async () => {
    const messaging = fakeMessaging();
    const request = draft({ action: { type: 'paywall' } });
    const id = request.notificationId;

    const result = await admin.sendNotificationHandler(depsWith(messaging), asAdmin(request));
    assert.deepEqual(result, { notificationId: id, status: 'sent', scheduledAt: null, recipients: 4 });

    const announcement = (await db.collection('announcements').doc(id).get()).data();
    assert.deepEqual(Object.keys(announcement).sort(), ['action', 'body', 'createdAt', 'kind', 'title']);
    assert.deepEqual(announcement.action, { type: 'paywall' });
    assert.ok(announcement.createdAt instanceof Timestamp);
    assert.deepEqual(await inboxOwners(id), []);

    assert.equal(messaging.multicasts.length, 0);
    assert.equal(messaging.topicMessages.length, 1);
    const push = messaging.topicMessages[0];
    assert.equal(push.topic, 'all');
    assert.deepEqual(push.data, { notificationId: id, kind: 'general' });
    assert.deepEqual(push.notification, { title: 'Başlık', body: 'Mesaj' });

    const stored = (await notificationDoc(id)).data();
    assert.equal(stored.status, 'sent');
    assert.equal(stored.delivery, 'broadcast');
    assert.equal(stored.audienceLabel, 'Tüm kullanıcılar');
    assert.deepEqual(stored.audience, { scope: 'all' });
    assert.equal(stored.source, 'admin');
    assert.equal(stored.createdBy, ADMIN_UID);
    assert.equal(stored.isTest, false);
    assert.equal(stored.scheduledAt, null);
    assert.equal(stored.expiresAt, null);
    assert.equal(stored.deferredByQuietHours, false);
    assert.equal('trigger' in stored, false);
    assert.equal('error' in stored, false);
    assert.ok(stored.createdAt instanceof Timestamp);
    assert.ok(stored.sentAt instanceof Timestamp);
    assert.deepEqual(stored.stats, { recipients: 4, pushTargets: 5, pushSent: 5, pushFailed: 0, opened: 0, actionTapped: 0 });
  });

  test('a segment fans out: inbox copies + device pushes for the members only', async () => {
    const messaging = fakeMessaging();
    const expiresAt = DAY.getTime() + 24 * 60 * 60 * 1000;
    const request = draft({ audience: segment({ facultyId: MUHENDISLIK }), expiresAt });
    const id = request.notificationId;

    const result = await admin.sendNotificationHandler(depsWith(messaging), asAdmin(request));
    assert.deepEqual(result, { notificationId: id, status: 'sent', scheduledAt: null, recipients: 2 });

    assert.deepEqual(await inboxOwners(id), ['ayse', 'mehmet']);
    const item = (await inboxDoc('ayse', id)).data();
    assert.deepEqual(Object.keys(item).sort(), ['body', 'createdAt', 'expiresAt', 'kind', 'title']);
    assert.equal(item.expiresAt.toMillis(), expiresAt);
    assert.ok(item.createdAt instanceof Timestamp);
    assert.equal((await db.collection('announcements').doc(id).get()).exists, false);

    assert.equal(messaging.topicMessages.length, 0);
    assert.equal(messaging.multicasts.length, 1);
    assert.deepEqual([...messaging.multicasts[0].tokens].sort(), ['tok-ayse', 'tok-mehmet-1', 'tok-mehmet-2']);
    assert.deepEqual(messaging.multicasts[0].data, { notificationId: id, kind: 'general' });

    const stored = (await notificationDoc(id)).data();
    assert.equal(stored.delivery, 'fanout');
    assert.equal(stored.audienceLabel, 'Ege Üniversitesi › Mühendislik Fakültesi');
    assert.equal(stored.expiresAt.toMillis(), expiresAt);
    assert.deepEqual(stored.stats, { recipients: 2, pushTargets: 3, pushSent: 3, pushFailed: 0, opened: 0, actionTapped: 0 });
  });

  test('department and gender segments reach exactly their members', async () => {
    const department = draft({ audience: segment({ facultyId: MUHENDISLIK, departmentId: BILGISAYAR }) });
    await admin.sendNotificationHandler(depsWith(), asAdmin(department));
    assert.deepEqual(await inboxOwners(department.notificationId), ['ayse']);
    assert.equal(
      (await notificationDoc(department.notificationId)).get('audienceLabel'),
      'Ege Üniversitesi › Mühendislik Fakültesi › Bilgisayar Mühendisliği'
    );

    const women = draft({ audience: segment({ gender: 'female' }) });
    await admin.sendNotificationHandler(depsWith(), asAdmin(women));
    assert.deepEqual(await inboxOwners(women.notificationId), ['ayse', 'zeynep']);
    assert.equal((await notificationDoc(women.notificationId)).get('audienceLabel'), 'Ege Üniversitesi · Kadın');
  });

  test('a campaign reaches only users who opted in, never through the public announcements', async () => {
    const messaging = fakeMessaging();
    const everyone = draft({ kind: 'promo' });
    const result = await admin.sendNotificationHandler(depsWith(messaging), asAdmin(everyone));
    assert.equal(result.recipients, 2);
    assert.deepEqual(await inboxOwners(everyone.notificationId), ['ali', 'ayse']);
    assert.equal((await db.collection('announcements').doc(everyone.notificationId).get()).exists, false);
    assert.equal(messaging.topicMessages.length, 0);
    assert.deepEqual([...messaging.multicasts[0].tokens].sort(), ['tok-ali', 'tok-ayse']);
    assert.equal(messaging.multicasts[0].data.kind, 'promo');

    const ege = draft({ kind: 'promo', audience: segment({}) });
    await admin.sendNotificationHandler(depsWith(messaging), asAdmin(ege));
    assert.deepEqual(await inboxOwners(ege.notificationId), ['ayse']); // mehmet declined, zeynep never answered
  });

  test('a location action makes it a campaign', async () => {
    const request = draft({ kind: 'general', action: { type: 'location', latitude: 38.45, longitude: 27.21, name: 'Kampüs Kafe' } });
    await admin.sendNotificationHandler(depsWith(), asAdmin(request));
    const stored = (await notificationDoc(request.notificationId)).data();
    assert.equal(stored.kind, 'promo');
    assert.equal(stored.delivery, 'fanout');
    assert.deepEqual(await inboxOwners(request.notificationId), ['ali', 'ayse']);
  });

  test('a test goes to its author only — right away, even a campaign at night, without consent', async () => {
    const messaging = fakeMessaging();
    const request = draft({ kind: 'promo', audience: { scope: 'segment', universityId: 'bogazici-universitesi' }, isTest: true });
    const result = await admin.sendNotificationHandler(depsWith(messaging, NIGHT), asAdmin(request));
    assert.deepEqual(result, { notificationId: request.notificationId, status: 'sent', scheduledAt: null, recipients: 1 });
    assert.deepEqual(await inboxOwners(request.notificationId), [ADMIN_UID]);
    assert.deepEqual(messaging.multicasts.map(({ tokens }) => tokens), [['tok-admin']]);

    const stored = (await notificationDoc(request.notificationId)).data();
    assert.equal(stored.isTest, true);
    assert.equal(stored.delivery, 'fanout');
    assert.equal(stored.scheduledAt, null);
    assert.equal(stored.deferredByQuietHours, false);
    assert.deepEqual(stored.audience, { scope: 'segment', universityId: 'bogazici-universitesi' });
    assert.equal(stored.audienceLabel, 'Boğaziçi Üniversitesi');
  });

  test('a general test is not broadcast either', async () => {
    const messaging = fakeMessaging();
    const request = draft({ isTest: true });
    await admin.sendNotificationHandler(depsWith(messaging), asAdmin(request));
    assert.equal(messaging.topicMessages.length, 0);
    assert.equal((await db.collection('announcements').doc(request.notificationId).get()).exists, false);
    assert.deepEqual(await inboxOwners(request.notificationId), [ADMIN_UID]);
  });

  test('is idempotent per notificationId: a retry returns the first result and sends nothing more', async () => {
    const messaging = fakeMessaging();
    const request = draft({ audience: segment({}) });
    const first = await admin.sendNotificationHandler(depsWith(messaging), asAdmin(request));
    const createdAt = (await notificationDoc(request.notificationId)).get('createdAt');

    const retry = await admin.sendNotificationHandler(depsWith(messaging), asAdmin({ ...request, title: 'Başka', audience: { scope: 'all' } }));
    assert.deepEqual(retry, first);
    assert.equal(messaging.multicasts.length, 1);
    assert.equal(messaging.topicMessages.length, 0);
    const stored = (await notificationDoc(request.notificationId)).data();
    assert.equal(stored.title, 'Başlık');
    assert.deepEqual(stored.createdAt, createdAt);
  });
});

// --- Exam action --------------------------------------------------------------------------------------------------

describe('exam action', () => {
  const ids = {
    university: EGE,
    faculty: `${EGE}__muhendislik`,
    department: `${EGE}__muhendislik__bilgisayar`,
    course: `${EGE}__muhendislik__bilgisayar__algoritmalar`,
  };

  beforeEach(async () => {
    await db.collection('exams').doc('exam-1').set({
      title: '2024 FİNAL', kind: 'PDF', status: 'published', files: [{ storagePath: 'pdfs/a.pdf', order: 0 }],
      universityId: ids.university, facultyId: ids.faculty, departmentId: ids.department, courseId: ids.course,
      universityName: 'EGE ÜNİVERSİTESİ', facultyName: 'MÜHENDİSLİK', departmentName: 'BİLGİSAYAR', courseName: 'ALGORİTMALAR',
    });
    // Older shape: only the course id; the ancestors come from the catalog's parent chain.
    await db.collection('exams').doc('exam-2').set({
      title: '2023 VİZE', kind: 'JPG', status: 'published', courseId: ids.course, files: [{ storagePath: 'imagess/a.jpg', order: 0 }],
    });
    await db.collection('exams').doc('exam-3').set({ title: '2025 VİZE', kind: 'JPG', status: 'pending', courseId: ids.course });
    const nodes = [
      [ids.university, 'EGE ÜNİVERSİTESİ', ''],
      [ids.faculty, 'MÜHENDİSLİK', ids.university],
      [ids.department, 'BİLGİSAYAR', ids.faculty],
      [ids.course, 'ALGORİTMALAR', ids.department],
    ];
    for (const [id, name, parentId] of nodes) {
      await db.collection('catalogNodes').doc(id).set({ name, parentId, status: 'published' });
    }
  });

  const expectedPath = (examId) => [ids.university, ids.faculty, ids.department, ids.course, examId];
  const expectedNames = (title) => ['EGE ÜNİVERSİTESİ', 'MÜHENDİSLİK', 'BİLGİSAYAR', 'ALGORİTMALAR', title];

  test('the server fills the path, names and kind from the published exam', async () => {
    const request = draft({ action: { type: 'exam', examId: 'exam-1' } });
    await admin.sendNotificationHandler(depsWith(), asAdmin(request));
    const expected = { type: 'exam', examId: 'exam-1', path: expectedPath('exam-1'), names: expectedNames('2024 FİNAL'), examKind: 'PDF' };
    assert.deepEqual((await notificationDoc(request.notificationId)).get('action'), expected);
    assert.deepEqual((await db.collection('announcements').doc(request.notificationId).get()).get('action'), expected);
  });

  test('an exam without denormalized ancestors is placed through the catalog chain', async () => {
    const request = draft({ audience: segment({}), action: { type: 'exam', examId: 'exam-2' } });
    await admin.sendNotificationHandler(depsWith(), asAdmin(request));
    assert.deepEqual((await inboxDoc('ayse', request.notificationId)).get('action'), {
      type: 'exam', examId: 'exam-2', path: expectedPath('exam-2'), names: expectedNames('2023 VİZE'), examKind: 'JPG',
    });
  });

  test('an unpublished or unknown exam is refused before anything is recorded', async () => {
    for (const examId of ['exam-3', 'exam-missing']) {
      const request = draft({ action: { type: 'exam', examId } });
      await assertHttpsError(
        admin.sendNotificationHandler(depsWith(), asAdmin(request)),
        'failed-precondition',
        'Bağlanacak sınav bulunamadı ya da yayında değil.'
      );
      assert.equal((await notificationDoc(request.notificationId)).exists, false);
    }
  });
});

// --- Scheduling and quiet hours -----------------------------------------------------------------------------------

describe('scheduling and quiet hours', () => {
  test('a future scheduledAt is only recorded as scheduled; nothing is delivered', async () => {
    const messaging = fakeMessaging();
    const scheduledAt = DAY.getTime() + 2 * 60 * 60 * 1000;
    const request = draft({ scheduledAt });
    const result = await admin.sendNotificationHandler(depsWith(messaging), asAdmin(request));
    assert.deepEqual(result, { notificationId: request.notificationId, status: 'scheduled', scheduledAt, recipients: 0 });

    const stored = (await notificationDoc(request.notificationId)).data();
    assert.equal(stored.status, 'scheduled');
    assert.equal(stored.scheduledAt.toMillis(), scheduledAt);
    assert.equal(stored.deferredByQuietHours, false);
    assert.equal('sentAt' in stored, false);
    assert.equal((await db.collection('announcements').doc(request.notificationId).get()).exists, false);
    assert.equal(messaging.topicMessages.length + messaging.multicasts.length, 0);

    // A retry reports the schedule too.
    assert.deepEqual(await admin.sendNotificationHandler(depsWith(messaging), asAdmin(request)), result);
  });

  test('a campaign composed in quiet hours waits for 09:00; a general notice goes now', async () => {
    const messaging = fakeMessaging();
    const promo = draft({ kind: 'promo' });
    const result = await admin.sendNotificationHandler(depsWith(messaging, NIGHT), asAdmin(promo));
    assert.deepEqual(result, { notificationId: promo.notificationId, status: 'scheduled', scheduledAt: NEXT_MORNING.getTime(), recipients: 0 });
    const stored = (await notificationDoc(promo.notificationId)).data();
    assert.equal(stored.deferredByQuietHours, true);
    assert.equal(stored.scheduledAt.toMillis(), NEXT_MORNING.getTime());
    assert.deepEqual(await inboxOwners(promo.notificationId), []);

    const general = draft();
    assert.equal((await admin.sendNotificationHandler(depsWith(messaging, NIGHT), asAdmin(general))).status, 'sent');
  });

  test('a campaign scheduled into quiet hours moves to 09:00', async () => {
    const promo = draft({ kind: 'promo', scheduledAt: new Date('2026-10-29T21:30:00Z').getTime() }); // 00:30 in Türkiye
    const result = await admin.sendNotificationHandler(depsWith(fakeMessaging(), DAY), asAdmin(promo));
    assert.equal(result.scheduledAt, NEXT_MORNING.getTime());
    assert.equal((await notificationDoc(promo.notificationId)).get('deferredByQuietHours'), true);
  });

  test('a campaign that would expire before quiet hours end is refused', async () => {
    const promo = draft({ kind: 'promo', expiresAt: NIGHT.getTime() + 30 * 60 * 1000 });
    await assertHttpsError(
      admin.sendNotificationHandler(depsWith(fakeMessaging(), NIGHT), asAdmin(promo)),
      'invalid-argument',
      'Geçerlilik süresi sessiz saatler (22:00–09:00) bitmeden doluyor.'
    );
    assert.equal((await notificationDoc(promo.notificationId)).exists, false);
  });
});

// --- Delivery -----------------------------------------------------------------------------------------------------

describe('deliverNotification', () => {
  test('prunes dead tokens and counts sent and failed pushes', async () => {
    await addDevice('zeynep', 'd-zeynep', 'tok-zeynep');
    const messaging = fakeMessaging({
      failures: {
        'tok-mehmet-1': 'messaging/registration-token-not-registered',
        'tok-zeynep': 'messaging/invalid-registration-token',
        'tok-ayse': 'messaging/internal-error', // transient: kept
      },
    });
    const request = draft({ audience: segment({}) });
    await admin.sendNotificationHandler(depsWith(messaging), asAdmin(request));

    assert.deepEqual((await notificationDoc(request.notificationId)).get('stats'), {
      recipients: 3, pushTargets: 4, pushSent: 1, pushFailed: 3, opened: 0, actionTapped: 0,
    });
    assert.equal((await deviceRef('mehmet', 'd-mehmet-1').get()).exists, false);
    assert.equal((await deviceRef('zeynep', 'd-zeynep').get()).exists, false);
    assert.equal((await deviceRef('mehmet', 'd-mehmet-2').get()).exists, true);
    assert.equal((await deviceRef('ayse', 'd-ayse').get()).exists, true);
    // Failed pushes never undo the inbox copies.
    assert.deepEqual(await inboxOwners(request.notificationId), ['ayse', 'mehmet', 'zeynep']);
  });

  test('pushes in batches of at most 500 tokens, and a token registered twice once', async () => {
    await rtdb.ref('users/crowd/profile').set(profile('Kalabalık Üniversitesi', 'kalabalik-universitesi', 'Fen', 'fen', 'Fizik', 'fizik', 'male', 'Can'));
    const writer = db.bulkWriter();
    for (let index = 0; index < 501; index += 1) {
      writer.set(deviceRef('crowd', `d-${index}`), { token: `tok-crowd-${index}`, platform: 'android', appVersion: '1.0', updatedAt: new Date() });
    }
    writer.set(deviceRef('crowd', 'd-again'), { token: 'tok-crowd-0', platform: 'android', appVersion: '1.0', updatedAt: new Date() });
    await writer.close();

    const messaging = fakeMessaging();
    const request = draft({ audience: { scope: 'segment', universityId: 'kalabalik-universitesi' } });
    await admin.sendNotificationHandler(depsWith(messaging), asAdmin(request));
    assert.deepEqual(messaging.multicasts.map(({ tokens }) => tokens.length), [500, 1]);
    const stats = (await notificationDoc(request.notificationId)).get('stats');
    assert.equal(stats.pushTargets, 501);
    assert.equal(stats.pushSent, 501);
  });

  test('a broadcast whose topic push fails is still sent (the announcement is out), with the push counted as failed', async () => {
    const request = draft();
    const result = await admin.sendNotificationHandler(depsWith(fakeMessaging({ topicError: 'FCM unavailable' })), asAdmin(request));
    assert.equal(result.status, 'sent');
    assert.equal((await db.collection('announcements').doc(request.notificationId).get()).exists, true);
    const stats = (await notificationDoc(request.notificationId)).get('stats');
    assert.equal(stats.pushSent, 0);
    assert.equal(stats.pushFailed, 5);
  });

  test('only a notification in "sending" is delivered; anything else is left alone', async () => {
    const messaging = fakeMessaging();
    await db.collection('notifications').doc('scheduled-1').set({
      kind: 'general', title: 'T', body: 'B', audience: { scope: 'all' }, delivery: 'broadcast', status: 'scheduled',
      stats: { recipients: 0, pushTargets: 0, pushSent: 0, pushFailed: 0, opened: 0, actionTapped: 0 },
    });
    const result = await deliver.deliverNotification(depsWith(messaging), 'scheduled-1');
    assert.equal(result.status, 'scheduled');
    assert.equal((await notificationDoc('scheduled-1')).get('status'), 'scheduled');
    assert.equal(messaging.topicMessages.length, 0);
    assert.equal((await db.collection('announcements').doc('scheduled-1').get()).exists, false);
  });

  test('a delivery that cannot resolve its recipients ends as failed with the error', async () => {
    await db.collection('notifications').doc('broken-1').set({
      kind: 'system', title: 'T', body: 'B', audience: { scope: 'admins' }, delivery: 'fanout', status: 'sending',
      isTest: false, stats: { recipients: 0, pushTargets: 0, pushSent: 0, pushFailed: 0, opened: 0, actionTapped: 0 },
    });
    const result = await deliver.deliverNotification(depsWith(), 'broken-1');
    assert.equal(result.status, 'failed');
    const stored = (await notificationDoc('broken-1')).data();
    assert.equal(stored.status, 'failed');
    assert.match(stored.error, /admins/);
  });

  test('a personal notice reaches its user only', async () => {
    const messaging = fakeMessaging();
    await db.collection('notifications').doc('personal-1').set({
      kind: 'system', title: 'Coin yüklendi', body: '+100', audience: { scope: 'user', uid: 'mehmet' }, delivery: 'fanout',
      status: 'sending', isTest: false, stats: { recipients: 0, pushTargets: 0, pushSent: 0, pushFailed: 0, opened: 0, actionTapped: 0 },
    });
    const result = await deliver.deliverNotification(depsWith(messaging), 'personal-1');
    assert.equal(result.status, 'sent');
    assert.equal(result.recipients, 1);
    assert.deepEqual(await inboxOwners('personal-1'), ['mehmet']);
    assert.deepEqual([...messaging.multicasts[0].tokens].sort(), ['tok-mehmet-1', 'tok-mehmet-2']);
  });
});

// --- Device dedupe ------------------------------------------------------------------------------------------------

describe('onDeviceWritten', () => {
  const missing = () => deviceRef('nobody', 'none').get();

  test('a token registered under a new account is removed from the other accounts', async () => {
    await addDevice('ayse', 'd-old', 'tok-shared');
    await addDevice('ali', 'd-ali-2', 'tok-shared');
    await addDevice('mehmet', 'd-new', 'tok-shared');
    // A non-user `devices` collection with the same token is not touched.
    await db.collection('labs').doc('x').collection('devices').doc('d').set({ token: 'tok-shared' });

    const after = await deviceRef('mehmet', 'd-new').get();
    const result = await fns.onDeviceWritten.run({ params: { uid: 'mehmet', deviceId: 'd-new' }, data: { before: await missing(), after } });
    assert.deepEqual(result, { removed: 2 });
    assert.equal((await deviceRef('ayse', 'd-old').get()).exists, false);
    assert.equal((await deviceRef('ali', 'd-ali-2').get()).exists, false);
    assert.equal((await deviceRef('mehmet', 'd-new').get()).exists, true);
    assert.equal((await db.collection('labs').doc('x').collection('devices').doc('d').get()).exists, true);
    assert.equal((await deviceRef('ayse', 'd-ayse').get()).exists, true);
  });

  test('an unchanged token, a deletion or a document without a token does nothing', async () => {
    await addDevice('ayse', 'd-old', 'tok-same');
    await addDevice('mehmet', 'd-new', 'tok-same');
    const snapshot = await deviceRef('mehmet', 'd-new').get();
    const params = { uid: 'mehmet', deviceId: 'd-new' };

    assert.deepEqual(await devices.onDeviceWrittenHandler({ db }, { params, data: { before: snapshot, after: snapshot } }), { removed: 0 });
    assert.deepEqual(await devices.onDeviceWrittenHandler({ db }, { params, data: { before: snapshot, after: await missing() } }), { removed: 0 });
    await db.collection('users').doc('mehmet').collection('devices').doc('d-empty').set({ platform: 'ios' });
    const empty = await deviceRef('mehmet', 'd-empty').get();
    assert.deepEqual(await devices.onDeviceWrittenHandler({ db }, { params, data: { before: await missing(), after: empty } }), { removed: 0 });
    assert.equal((await deviceRef('ayse', 'd-old').get()).exists, true);
  });
});

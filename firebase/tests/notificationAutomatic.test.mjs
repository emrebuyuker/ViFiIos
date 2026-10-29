// The automatic notifications (`functions/notifications/automatic.js`) against the Firestore and Realtime Database
// emulators: the moderation transitions (approved / rejected, non-transitions, redelivered events), the ledger
// amount, the department slugs, the daily department limit, uploader exclusion, quiet hours, and the `admins`
// audience (a fake Auth `listUsers`, plus one wiring check against the Auth emulator). FCM is a fake that records
// what would have been pushed; nothing leaves this machine.

import { test, before, after, beforeEach, describe, mock } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { assertLocalEmulators, PROJECT_ID } from './helpers.mjs';

const requireFromFunctions = createRequire(new URL('../functions/package.json', import.meta.url));
const { getFirestore, Timestamp } = requireFromFunctions('firebase-admin/firestore');
const { getDatabase } = requireFromFunctions('firebase-admin/database');
const { getAuth } = requireFromFunctions('firebase-admin/auth');
const { getApp, deleteApp } = requireFromFunctions('firebase-admin/app');

const DAY = new Date('2026-10-29T09:00:00Z'); // 12:00 in Türkiye
const NIGHT = new Date('2026-10-29T20:00:00Z'); // 23:00 in Türkiye
const NEXT_MORNING = new Date('2026-10-30T06:00:00Z'); // 09:00 in Türkiye
const NEXT_DAY = new Date('2026-10-30T07:00:00Z'); // 10:00 in Türkiye

const EGE = 'ege-universitesi';
const MUHENDISLIK = 'muhendislik-fakultesi';
const BILGISAYAR = 'bilgisayar-muhendisligi';
const MAKINE = 'makine-muhendisligi';

// Archive (composite) ids, as iOS `ArchivePublishPlan` builds them.
const FACULTY_ID = `${EGE}__${MUHENDISLIK}`;
const DEPARTMENTS = {
  bilgisayar: { id: `${FACULTY_ID}__${BILGISAYAR}`, name: 'Bilgisayar Mühendisliği', course: 'Algoritmalar' },
  makine: { id: `${FACULTY_ID}__${MAKINE}`, name: 'Makine Mühendisliği', course: 'Statik' },
};

let db;
let rtdb;
let fns;
let automatic;
let audience;
let deliver;

before(async () => {
  assertLocalEmulators('FIRESTORE_EMULATOR_HOST', 'FIREBASE_DATABASE_EMULATOR_HOST', 'FIREBASE_AUTH_EMULATOR_HOST');
  mock.method(console, 'error', () => {});
  mock.method(console, 'warn', () => {});
  fns = await import('../functions/index.js');
  automatic = await import('../functions/notifications/automatic.js');
  audience = await import('../functions/notifications/audience.js');
  deliver = await import('../functions/notifications/deliver.js');
  db = getFirestore('vifi');
  // The default database of the emulator run's FIREBASE_CONFIG — the one the live dependencies use too.
  rtdb = getDatabase();
});

after(async () => {
  await deleteApp(getApp());
});

// --- Fixtures -----------------------------------------------------------------------------------------------------

function profile(departmentId, department, gender, name, universityId = EGE, facultyId = MUHENDISLIK) {
  return {
    name, surname: 'Örnekoğlu', university: 'Ege Üniversitesi', universityId, universityIsCustom: false,
    faculty: 'Mühendislik Fakültesi', facultyId, facultyIsCustom: false, department, departmentId,
    departmentIsCustom: false, gender, updatedAt: 1_700_000_000_000,
  };
}

const PROFILES = {
  ayse: profile(BILGISAYAR, 'Bilgisayar Mühendisliği', 'female', 'Ayşe'), // the uploader
  can: profile(BILGISAYAR, 'Bilgisayar Mühendisliği', 'male', 'Can'),
  deniz: profile(BILGISAYAR, 'Bilgisayar Mühendisliği', 'female', 'Deniz'), // no device
  mehmet: profile(MAKINE, 'Makine Mühendisliği', 'male', 'Mehmet'),
  zeynep: profile(BILGISAYAR, 'Bilgisayar Mühendisliği', 'female', 'Zeynep', 'bogazici-universitesi'),
};

const DEVICES = { ayse: 'tok-ayse', can: 'tok-can', mehmet: 'tok-mehmet', zeynep: 'tok-zeynep', 'admin-1': 'tok-admin-1' };

const notificationDoc = (id) => db.collection('notifications').doc(id).get();
const inboxDoc = (uid, id) => db.collection('users').doc(uid).collection('inbox').doc(id).get();
const throttleDoc = (key) => db.collection('notificationThrottle').doc(key).get();

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
  await writer.close();
});

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
  return fake;
}

/** Pushed tokens per notification id. */
function pushedTokens(messaging) {
  const byId = {};
  for (const message of messaging.multicasts) {
    byId[message.data.notificationId] = [...(byId[message.data.notificationId] ?? []), ...message.tokens].sort();
  }
  return byId;
}

/** A fake Auth client: `pages` are `listUsers` pages of `{ uid, customClaims?, disabled? }`. */
function fakeAuth(pages) {
  const auth = {
    calls: 0,
    async listUsers(maxResults, pageToken) {
      auth.calls += 1;
      const index = pageToken ? Number(pageToken) : 0;
      const next = index + 1 < pages.length ? String(index + 1) : undefined;
      return { users: pages[index] ?? [], pageToken: next };
    },
  };
  return auth;
}

function depsWith({ messaging = fakeMessaging(), now = DAY, auth = fakeAuth([[]]) } = {}) {
  return { db, rtdb, messaging, auth, now: () => now };
}

/** Publishes a department's exam the way the iOS approval does (denormalized names), returning its id. */
async function publishExam(department, examId = `${department.id}__${department.course.toLowerCase()}__2024-final`) {
  await db.collection('exams').doc(examId).set({
    title: '2024 FİNAL', kind: 'PDF', status: 'published', files: [{ storagePath: 'pdfs/a.pdf', order: 0 }],
    universityId: EGE, facultyId: FACULTY_ID, departmentId: department.id, courseId: `${department.id}__course`,
    universityName: 'Ege Üniversitesi', facultyName: 'Mühendislik Fakültesi', departmentName: department.name,
    courseName: department.course,
  });
  return examId;
}

async function createSubmission(id, { ownerId = 'ayse', department = DEPARTMENTS.bilgisayar, status = 'pending' } = {}) {
  const ref = db.collection('submissions').doc(id);
  await ref.set({
    ownerId, university: 'Ege Üniversitesi', faculty: 'Mühendislik Fakültesi', department: department.name,
    lesson: department.course, exam: '2024 FİNAL', kind: 'PDF', status, createdAt: new Date(),
    files: [{ storagePath: `pending/${ownerId}/${id}/0.pdf`, order: 0 }],
  });
  return ref;
}

/** Applies `changes` to a submission and returns the `onDocumentUpdated` event for it. */
async function updateEvent(ref, changes) {
  const before = await ref.get();
  await ref.update(changes);
  return { params: { id: ref.id }, data: { before, after: await ref.get() } };
}

/** A pending submission approved as the admin's app does it: exam published, coins credited, status changed. */
async function approve(id, { coins = 50, publish = true, department = DEPARTMENTS.bilgisayar, ownerId = 'ayse' } = {}) {
  const ref = await createSubmission(id, { ownerId, department });
  const examId = publish ? await publishExam(department, `${department.id}__exam-${id}`) : null;
  if (coins > 0) {
    await db.collection('wallets').doc(ownerId).collection('ledger').doc(id).set({
      type: 'earn', amount: coins, submissionId: id, tier: 'newExam', createdAt: new Date(),
    });
  }
  const changes = { status: 'approved', tier: 'newExam', coins, reviewedAt: new Date() };
  if (examId) changes.publishedExamId = examId;
  return { event: await updateEvent(ref, changes), examId };
}

async function inboxOwners(id) {
  const owners = [];
  for (const uid of [...Object.keys(PROFILES), 'admin-1', 'admin-2']) {
    if ((await inboxDoc(uid, id)).exists) owners.push(uid);
  }
  return owners.sort();
}

const BILGISAYAR_SEGMENT = { scope: 'segment', universityId: EGE, facultyId: MUHENDISLIK, departmentId: BILGISAYAR };

// --- Approval -----------------------------------------------------------------------------------------------------

describe('onSubmissionModerated: approval', () => {
  test('notifies the uploader with the credited coins and the department about the new exam', async () => {
    const messaging = fakeMessaging();
    const { event, examId } = await approve('sub-1');
    const result = await automatic.onSubmissionModeratedHandler(depsWith({ messaging }), event);
    assert.deepEqual(result, { owner: 'sent', department: 'sent' });

    const expectedAction = {
      type: 'exam',
      examId,
      path: [EGE, FACULTY_ID, DEPARTMENTS.bilgisayar.id, `${DEPARTMENTS.bilgisayar.id}__course`, examId],
      names: ['Ege Üniversitesi', 'Mühendislik Fakültesi', 'Bilgisayar Mühendisliği', 'Algoritmalar', '2024 FİNAL'],
      examKind: 'PDF',
    };

    const owner = (await notificationDoc('auto-approved-sub-1')).data();
    assert.equal(owner.kind, 'system');
    assert.equal(owner.source, 'automatic');
    assert.equal(owner.trigger, 'submissionApproved');
    assert.equal(owner.createdBy, 'system');
    assert.equal(owner.title, 'Sınavın onaylandı');
    assert.equal(owner.body, 'Algoritmalar – 2024 FİNAL arşive eklendi. +50 coin hesabına yüklendi.');
    assert.deepEqual(owner.audience, { scope: 'user', uid: 'ayse' });
    assert.equal(owner.audienceLabel, 'Kişisel');
    assert.equal(owner.delivery, 'fanout');
    assert.equal(owner.status, 'sent');
    assert.equal(owner.isTest, false);
    assert.equal(owner.scheduledAt, null);
    assert.deepEqual(owner.action, expectedAction);
    assert.deepEqual(await inboxOwners('auto-approved-sub-1'), ['ayse']);
    assert.deepEqual((await inboxDoc('ayse', 'auto-approved-sub-1')).get('action'), expectedAction);

    const department = (await notificationDoc('auto-newexam-sub-1')).data();
    assert.equal(department.kind, 'system');
    assert.equal(department.trigger, 'newExam');
    assert.equal(department.source, 'automatic');
    assert.equal(department.createdBy, 'system');
    assert.equal(department.title, 'Bölümüne yeni sınav eklendi');
    assert.equal(department.body, 'Algoritmalar – 2024 FİNAL arşive eklendi. Hemen göz at!');
    assert.deepEqual(department.audience, BILGISAYAR_SEGMENT);
    assert.equal(department.audienceLabel, 'Ege Üniversitesi › Mühendislik Fakültesi › Bilgisayar Mühendisliği');
    assert.deepEqual(department.excludeUids, ['ayse']);
    assert.equal(department.status, 'sent');
    assert.equal(department.deferredByQuietHours, false);
    assert.deepEqual(department.action, expectedAction);
    assert.equal(department.stats.recipients, 2);
    // The uploader, another department and another university are left out.
    assert.deepEqual(await inboxOwners('auto-newexam-sub-1'), ['can', 'deniz']);

    assert.deepEqual(pushedTokens(messaging), { 'auto-approved-sub-1': ['tok-ayse'], 'auto-newexam-sub-1': ['tok-can'] });
    assert.equal(messaging.topicMessages.length, 0);
    for (const message of messaging.multicasts) assert.equal(message.data.kind, 'system');

    const throttle = (await throttleDoc(`${EGE}__${MUHENDISLIK}__${BILGISAYAR}`)).data();
    assert.equal(throttle.lastSentAt.toMillis(), DAY.getTime());
    assert.equal(throttle.notificationId, 'auto-newexam-sub-1');
  });

  test('a redelivered event sends nothing twice', async () => {
    const messaging = fakeMessaging();
    const { event } = await approve('sub-1');
    await automatic.onSubmissionModeratedHandler(depsWith({ messaging }), event);
    const pushes = messaging.multicasts.length;

    const again = await automatic.onSubmissionModeratedHandler(depsWith({ messaging, now: NEXT_DAY }), event);
    assert.deepEqual(again, { owner: 'duplicate', department: 'duplicate' });
    assert.equal(messaging.multicasts.length, pushes);
    // The throttle still records the first send.
    const throttle = (await throttleDoc(`${EGE}__${MUHENDISLIK}__${BILGISAYAR}`)).data();
    assert.equal(throttle.lastSentAt.toMillis(), DAY.getTime());
  });

  test('without a ledger entry the amount is left out; a duplicate exam gets no link and no department notice', async () => {
    const messaging = fakeMessaging();
    const { event } = await approve('sub-1', { coins: 0, publish: false });
    const result = await automatic.onSubmissionModeratedHandler(depsWith({ messaging }), event);
    assert.deepEqual(result, { owner: 'sent', department: 'no-new-exam' });

    const owner = (await notificationDoc('auto-approved-sub-1')).data();
    assert.equal(owner.body, 'Algoritmalar – 2024 FİNAL gönderin onaylandı. Katkın için teşekkürler!');
    assert.equal('action' in owner, false);
    assert.equal((await notificationDoc('auto-newexam-sub-1')).exists, false);
    assert.deepEqual(pushedTokens(messaging), { 'auto-approved-sub-1': ['tok-ayse'] });
  });

  test('a published exam whose path has no profile slugs gets the link but no department notice', async () => {
    const ref = await createSubmission('sub-odd');
    await db.collection('exams').doc('legacy-exam').set({
      title: '2019 VİZE', kind: 'JPG', status: 'published', universityId: 'ege', facultyId: 'muh', departmentId: 'bil',
      courseId: 'alg', universityName: 'Ege', facultyName: 'Mühendislik', departmentName: 'Bilgisayar', courseName: 'Algoritmalar',
    });
    const event = await updateEvent(ref, { status: 'approved', coins: 0, publishedExamId: 'legacy-exam' });
    const result = await automatic.onSubmissionModeratedHandler(depsWith(), event);
    assert.deepEqual(result, { owner: 'sent', department: 'no-department' });
    assert.equal((await notificationDoc('auto-approved-sub-odd')).get('action').examId, 'legacy-exam');
  });
});

// --- Non-transitions ----------------------------------------------------------------------------------------------

describe('onSubmissionModerated: only pending → approved | rejected', () => {
  test('every other update does nothing', async () => {
    const messaging = fakeMessaging();
    const deps = depsWith({ messaging });

    const pending = await createSubmission('sub-a');
    const stillPending = await updateEvent(pending, { lesson: 'Veri Yapıları' });
    assert.deepEqual(await automatic.onSubmissionModeratedHandler(deps, stillPending), { skipped: 'not-moderated' });

    const approved = await createSubmission('sub-b', { status: 'approved' });
    const reApproved = await updateEvent(approved, { coins: 10 });
    assert.deepEqual(await automatic.onSubmissionModeratedHandler(deps, reApproved), { skipped: 'not-moderated' });

    const rejected = await createSubmission('sub-c', { status: 'rejected' });
    const flipped = await updateEvent(rejected, { status: 'approved' });
    assert.deepEqual(await automatic.onSubmissionModeratedHandler(deps, flipped), { skipped: 'not-moderated' });

    const missing = await db.collection('submissions').doc('nope').get();
    const deleted = { params: { id: 'sub-a' }, data: { before: await pending.get(), after: missing } };
    assert.deepEqual(await automatic.onSubmissionModeratedHandler(deps, deleted), { skipped: 'not-moderated' });

    const unknown = await updateEvent(await createSubmission('sub-d'), { status: 'archived' });
    assert.deepEqual(await automatic.onSubmissionModeratedHandler(deps, unknown), { skipped: 'not-moderated' });

    // The deployed trigger is wired to the same handler.
    assert.deepEqual(await fns.onSubmissionModerated.run(stillPending), { skipped: 'not-moderated' });

    assert.equal((await db.collection('notifications').get()).size, 0);
    assert.equal(messaging.multicasts.length, 0);
  });
});

// --- Rejection ----------------------------------------------------------------------------------------------------

describe('onSubmissionModerated: rejection', () => {
  test('tells the uploader, with the reason when there is one', async () => {
    const messaging = fakeMessaging();
    const withReason = await updateEvent(await createSubmission('sub-r1'), {
      status: 'rejected', rejectionReason: '  Görseller okunmuyor.  ', reviewedAt: new Date(),
    });
    assert.deepEqual(await automatic.onSubmissionModeratedHandler(depsWith({ messaging, now: NIGHT }), withReason), { owner: 'sent' });
    const notice = (await notificationDoc('auto-rejected-sub-r1')).data();
    assert.equal(notice.title, 'Gönderin reddedildi');
    assert.equal(notice.body, 'Algoritmalar – 2024 FİNAL gönderin onaylanmadı. Sebep: Görseller okunmuyor.');
    assert.equal(notice.trigger, 'submissionRejected');
    assert.equal(notice.source, 'automatic');
    assert.deepEqual(notice.audience, { scope: 'user', uid: 'ayse' });
    // Personal notices are never held over quiet hours.
    assert.equal(notice.status, 'sent');
    assert.equal('action' in notice, false);
    assert.deepEqual(await inboxOwners('auto-rejected-sub-r1'), ['ayse']);

    const withoutReason = await updateEvent(await createSubmission('sub-r2'), { status: 'rejected' });
    await automatic.onSubmissionModeratedHandler(depsWith({ messaging }), withoutReason);
    assert.equal((await notificationDoc('auto-rejected-sub-r2')).get('body'), 'Algoritmalar – 2024 FİNAL gönderin onaylanmadı.');

    assert.deepEqual(pushedTokens(messaging), { 'auto-rejected-sub-r1': ['tok-ayse'], 'auto-rejected-sub-r2': ['tok-ayse'] });
    assert.equal((await notificationDoc('auto-newexam-sub-r1')).exists, false);
    assert.equal((await db.collection('notificationThrottle').get()).size, 0);
  });
});

// --- Daily department limit and quiet hours -----------------------------------------------------------------------

describe('department "new exam" limit and quiet hours', () => {
  test('a second approval in the same department the same day sends no department notice', async () => {
    const messaging = fakeMessaging();
    await automatic.onSubmissionModeratedHandler(depsWith({ messaging }), (await approve('sub-1')).event);

    const later = new Date(DAY.getTime() + 6 * 60 * 60 * 1000); // 18:00 in Türkiye
    const second = await automatic.onSubmissionModeratedHandler(depsWith({ messaging, now: later }), (await approve('sub-2')).event);
    assert.deepEqual(second, { owner: 'sent', department: 'throttled' });
    assert.equal((await notificationDoc('auto-newexam-sub-2')).exists, false);
    assert.equal((await notificationDoc('auto-approved-sub-2')).get('status'), 'sent');

    // Another department the same day has its own limit.
    const makine = await approve('sub-3', { department: DEPARTMENTS.makine, ownerId: 'can' });
    assert.deepEqual(await automatic.onSubmissionModeratedHandler(depsWith({ messaging, now: later }), makine.event), {
      owner: 'sent', department: 'sent',
    });
    assert.deepEqual(await inboxOwners('auto-newexam-sub-3'), ['mehmet']);

    // The next day the department is notified again.
    const nextDay = await automatic.onSubmissionModeratedHandler(depsWith({ messaging, now: NEXT_DAY }), (await approve('sub-4')).event);
    assert.deepEqual(nextDay, { owner: 'sent', department: 'sent' });
    assert.deepEqual(await inboxOwners('auto-newexam-sub-4'), ['can', 'deniz']);
  });

  test('during quiet hours the department notice waits for 09:00 and counts for that day', async () => {
    const messaging = fakeMessaging();
    const result = await automatic.onSubmissionModeratedHandler(depsWith({ messaging, now: NIGHT }), (await approve('sub-1')).event);
    assert.deepEqual(result, { owner: 'sent', department: 'scheduled' });

    const department = (await notificationDoc('auto-newexam-sub-1')).data();
    assert.equal(department.status, 'scheduled');
    assert.equal(department.scheduledAt.toMillis(), NEXT_MORNING.getTime());
    assert.equal(department.deferredByQuietHours, true);
    assert.deepEqual(await inboxOwners('auto-newexam-sub-1'), []);
    // The uploader's own notice is not held.
    assert.deepEqual(pushedTokens(messaging), { 'auto-approved-sub-1': ['tok-ayse'] });
    const throttle = (await throttleDoc(`${EGE}__${MUHENDISLIK}__${BILGISAYAR}`)).data();
    assert.equal(throttle.lastSentAt.toMillis(), NEXT_MORNING.getTime());

    // An approval the next morning lands on the same delivery day: no second department notice.
    const morning = await automatic.onSubmissionModeratedHandler(depsWith({ messaging, now: NEXT_DAY }), (await approve('sub-2')).event);
    assert.deepEqual(morning, { owner: 'sent', department: 'throttled' });

    // When the dispatcher delivers the held notice (scheduled → sending), the uploader is still left out.
    await db.collection('notifications').doc('auto-newexam-sub-1').update({ status: 'sending' });
    const delivered = await deliver.deliverNotification(depsWith({ messaging, now: NEXT_MORNING }), 'auto-newexam-sub-1');
    assert.equal(delivered.status, 'sent');
    assert.deepEqual(await inboxOwners('auto-newexam-sub-1'), ['can', 'deniz']);
  });

  test('concurrent approvals in one department make a single department notice', async () => {
    const first = await approve('sub-1');
    const second = await approve('sub-2');
    const results = await Promise.all([
      automatic.onSubmissionModeratedHandler(depsWith(), first.event),
      automatic.onSubmissionModeratedHandler(depsWith(), second.event),
    ]);
    assert.deepEqual(results.map(({ department }) => department).sort(), ['sent', 'throttled']);
    const departmentNotices = (await db.collection('notifications').where('trigger', '==', 'newExam').get()).size;
    assert.equal(departmentNotices, 1);
  });
});

// --- Pure helpers -------------------------------------------------------------------------------------------------

describe('department slugs and the Istanbul day', () => {
  test('the archive path splits into the profile segment', () => {
    const path = [EGE, FACULTY_ID, DEPARTMENTS.bilgisayar.id, 'course', 'exam'];
    assert.deepEqual(automatic.departmentSegment(path), BILGISAYAR_SEGMENT);
    assert.equal(automatic.throttleKey(BILGISAYAR_SEGMENT), `${EGE}__${MUHENDISLIK}__${BILGISAYAR}`);

    for (const broken of [
      ['ege', 'muh', 'bil', 'c', 'e'], // legacy ids without the composite shape
      [EGE, FACULTY_ID, `${FACULTY_ID}__${BILGISAYAR}__extra`, 'c', 'e'],
      ['other', FACULTY_ID, DEPARTMENTS.bilgisayar.id, 'c', 'e'], // ancestors disagree
      [EGE, `${EGE}__x`, DEPARTMENTS.bilgisayar.id, 'c', 'e'],
      [EGE, FACULTY_ID, `${FACULTY_ID}__Bilgisayar`, 'c', 'e'], // not a slug
      [EGE, FACULTY_ID],
      null,
    ]) {
      assert.equal(automatic.departmentSegment(broken), null, JSON.stringify(broken));
    }
  });

  test('days change at midnight in Türkiye, not UTC', () => {
    const lateEvening = new Date('2026-10-29T20:59:00Z'); // 23:59 in Türkiye
    const midnight = new Date('2026-10-29T21:00:00Z'); // 00:00 in Türkiye
    assert.equal(automatic.sameIstanbulDay(DAY, lateEvening), true);
    assert.equal(automatic.sameIstanbulDay(lateEvening, midnight), false);
    assert.equal(automatic.sameIstanbulDay(midnight, NEXT_DAY), true);
  });

  test('every automatic id fits the notification id pattern', () => {
    const ids = automatic.automaticNotificationIds('AbC123xyz_-AbC123xyz');
    for (const id of Object.values(ids)) assert.match(id, /^[A-Za-z0-9_-]{1,128}$/);
  });
});

// --- New submission → admins --------------------------------------------------------------------------------------

describe('onSubmissionCreated', () => {
  const ADMIN_PAGES = [
    [
      { uid: 'admin-1', customClaims: { admin: true } },
      { uid: 'ayse' },
      { uid: 'string-admin', customClaims: { admin: 'true' } },
    ],
    [
      { uid: 'admin-2', customClaims: { admin: true, other: 1 } },
      { uid: 'disabled-admin', customClaims: { admin: true }, disabled: true },
    ],
  ];

  test('notifies every admin right away, even in quiet hours', async () => {
    const messaging = fakeMessaging();
    const auth = fakeAuth(ADMIN_PAGES);
    const snapshot = await (await createSubmission('sub-new')).get();
    const event = { params: { id: 'sub-new' }, data: snapshot };
    assert.deepEqual(await automatic.onSubmissionCreatedHandler(depsWith({ messaging, auth, now: NIGHT }), event), { admins: 'sent' });

    const notice = (await notificationDoc('auto-submission-sub-new')).data();
    assert.equal(notice.kind, 'system');
    assert.equal(notice.trigger, 'newSubmission');
    assert.equal(notice.source, 'automatic');
    assert.equal(notice.createdBy, 'system');
    assert.equal(notice.title, 'Yeni sınav gönderimi');
    assert.equal(notice.body, 'Algoritmalar – 2024 FİNAL (Ege Üniversitesi › Bilgisayar Mühendisliği) incelemeni bekliyor.');
    assert.deepEqual(notice.audience, { scope: 'admins' });
    assert.equal(notice.audienceLabel, 'Adminler');
    assert.equal(notice.status, 'sent');
    assert.equal(notice.stats.recipients, 2);
    assert.deepEqual(await inboxOwners('auto-submission-sub-new'), ['admin-1', 'admin-2']);
    assert.deepEqual(pushedTokens(messaging), { 'auto-submission-sub-new': ['tok-admin-1'] });

    // A redelivered event sends nothing twice.
    assert.deepEqual(await automatic.onSubmissionCreatedHandler(depsWith({ messaging, auth }), event), { admins: 'duplicate' });
    assert.equal(messaging.multicasts.length, 1);
  });

  test('one uploader reaches the admins at most 3 times an hour; other uploaders are not held back', async () => {
    const messaging = fakeMessaging();
    const auth = fakeAuth(ADMIN_PAGES);
    const minute = 60 * 1000;
    const created = async (id, ownerId, minutesAfter) => {
      const snapshot = await (await createSubmission(id, { ownerId })).get();
      const now = new Date(DAY.getTime() + minutesAfter * minute);
      return automatic.onSubmissionCreatedHandler(depsWith({ messaging, auth, now }), { params: { id }, data: snapshot });
    };

    for (let index = 0; index < automatic.ADMIN_NOTICE_LIMIT; index += 1) {
      assert.deepEqual(await created(`flood-${index}`, 'ayse', index), { admins: 'sent' });
    }
    assert.deepEqual(await created('flood-3', 'ayse', 3), { admins: 'throttled' });
    assert.equal((await notificationDoc('auto-submission-flood-3')).exists, false);
    assert.deepEqual(await created('other-0', 'mehmet', 4), { admins: 'sent' });
    // An hour after the first notice, one more fits the rolling window.
    assert.deepEqual(await created('flood-4', 'ayse', 61), { admins: 'sent' });
    assert.equal(messaging.multicasts.length, 5);
  });

  test('a submission that is not pending is ignored', async () => {
    const snapshot = await (await createSubmission('sub-odd', { status: 'approved' })).get();
    const result = await automatic.onSubmissionCreatedHandler(depsWith(), { params: { id: 'sub-odd' }, data: snapshot });
    assert.deepEqual(result, { admins: 'not-pending' });
    assert.equal((await notificationDoc('auto-submission-sub-odd')).exists, false);
  });

  test('the admin list pages through listUsers and is cached per instance for a few minutes', async () => {
    const auth = fakeAuth(ADMIN_PAGES);
    const start = DAY.getTime();
    assert.deepEqual(await audience.loadAdminUids(auth, { now: start }), ['admin-1', 'admin-2']);
    assert.equal(auth.calls, 2);
    assert.deepEqual(await audience.loadAdminUids(auth, { now: start + audience.ADMIN_CACHE_TTL_MS - 1 }), ['admin-1', 'admin-2']);
    assert.equal(auth.calls, 2);
    await audience.loadAdminUids(auth, { now: start + audience.ADMIN_CACHE_TTL_MS });
    assert.equal(auth.calls, 4);

    // Without an Auth client the admins cannot be resolved (the delivery then fails instead of guessing).
    await assert.rejects(
      audience.resolveRecipients({ db, rtdb }, { kind: 'system', audience: { scope: 'admins' } }),
      /needs the Auth client/
    );
  });

  test('the deployed trigger resolves the admins from Firebase Auth', async () => {
    const auth = getAuth();
    const uid = `auto-admin-${process.pid}`;
    await auth.createUser({ uid });
    await auth.setCustomUserClaims(uid, { admin: true });
    try {
      const snapshot = await (await createSubmission('sub-live')).get();
      // The new admin has no registered device, so the live FCM client is never called.
      const result = await fns.onSubmissionCreated.run({ params: { id: 'sub-live' }, data: snapshot });
      assert.deepEqual(result, { admins: 'sent' });
      assert.equal((await inboxDoc(uid, 'auto-submission-sub-live')).exists, true);
    } finally {
      await auth.deleteUser(uid);
    }
  });
});

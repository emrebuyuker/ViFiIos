// The structured-exam admin callables and publishing (`functions/conversions/{admin,publish,jobs}.js`) against the
// Firestore and Realtime Database emulators: the admin gate, starting / re-running jobs (a fake task queue records
// what would be enqueued), the bulk estimate, the second approval's publish transaction (catalog nodes, exam,
// questions, pools, subjects, department notice), discarding, editing and regenerating published questions, and the
// exam-deletion cleanup. FCM is a fake; nothing leaves this machine and no AI is called.

import { test, before, after, beforeEach, describe, mock } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { assertLocalEmulators, PROJECT_ID } from './helpers.mjs';

const requireFromFunctions = createRequire(new URL('../functions/package.json', import.meta.url));
const { getFirestore } = requireFromFunctions('firebase-admin/firestore');
const { getDatabase } = requireFromFunctions('firebase-admin/database');
const { getApp, deleteApp } = requireFromFunctions('firebase-admin/app');

const DAY = new Date('2026-11-13T09:00:00Z'); // 12:00 in Türkiye

const EGE = 'ege-universitesi';
const FACULTY = `${EGE}__muhendislik-fakultesi`;
const DEPARTMENT = `${FACULTY}__bilgisayar-muhendisligi`;
const COURSE = `${DEPARTMENT}__algoritmalar`;
const NAMES = {
  university: 'Ege Üniversitesi', faculty: 'Mühendislik Fakültesi', department: 'Bilgisayar Mühendisliği', course: 'Algoritmalar',
};

let db;
let rtdb;
let fns;
let admin;
let publish;
let schema;

before(async () => {
  assertLocalEmulators('FIRESTORE_EMULATOR_HOST', 'FIREBASE_DATABASE_EMULATOR_HOST');
  mock.method(console, 'error', () => {});
  mock.method(console, 'warn', () => {});
  fns = await import('../functions/index.js');
  admin = await import('../functions/conversions/admin.js');
  publish = await import('../functions/conversions/publish.js');
  schema = await import('../functions/conversions/schema.js');
  db = getFirestore('vifi');
  rtdb = getDatabase();
});

after(async () => {
  await deleteApp(getApp());
});

async function clearFirestore() {
  const host = process.env.FIRESTORE_EMULATOR_HOST;
  const response = await fetch(`http://${host}/emulator/v1/projects/${PROJECT_ID}/databases/vifi/documents`, { method: 'DELETE' });
  assert.ok(response.ok, `clearing the Firestore emulator failed: ${response.status}`);
}

const profile = (name) => ({
  name, surname: 'Örnek', university: NAMES.university, universityId: EGE, universityIsCustom: false,
  faculty: NAMES.faculty, facultyId: 'muhendislik-fakultesi', facultyIsCustom: false, department: NAMES.department,
  departmentId: 'bilgisayar-muhendisligi', departmentIsCustom: false, gender: 'female', updatedAt: 1_700_000_000_000,
});

beforeEach(async () => {
  await clearFirestore();
  await rtdb.ref('users').set({ ayse: { profile: profile('Ayşe') }, can: { profile: profile('Can') } });
});

// --- Fakes and fixtures -------------------------------------------------------------------------------------------

function fakeQueue() {
  const tasks = [];
  return { tasks, enqueueConversion: async (jobId, options = {}) => { tasks.push({ jobId, ...options }); } };
}

function fakeMessaging() {
  return {
    async send() { return 'm'; },
    async sendEachForMulticast(message) {
      return { successCount: message.tokens.length, failureCount: 0, responses: message.tokens.map(() => ({ success: true })) };
    },
  };
}

function fakeBucket() {
  const deleted = [];
  return { deleted, async deleteFiles({ prefix }) { deleted.push(prefix); } };
}

function depsWith({ queue = fakeQueue(), bucket = fakeBucket(), now = DAY } = {}) {
  return { db, rtdb, messaging: fakeMessaging(), bucket, now: () => now, enqueueConversion: queue.enqueueConversion };
}

const ADMIN = { uid: 'admin-1', token: { admin: true } };
const asAdmin = (data) => ({ auth: ADMIN, data });

const job = (id) => db.collection('examConversions').doc(id);
const getData = async (ref) => (await ref.get()).data();

async function seedCatalog({ course = true } = {}) {
  const nodes = db.collection('catalogNodes');
  await nodes.doc(EGE).set({ level: 'university', name: NAMES.university, parentId: '', status: 'published', childCount: 1 });
  await nodes.doc(FACULTY).set({ level: 'faculty', name: NAMES.faculty, parentId: EGE, status: 'published', childCount: 1 });
  await nodes.doc(DEPARTMENT).set({ level: 'department', name: NAMES.department, parentId: FACULTY, status: 'published', childCount: 2 });
  if (course) {
    await nodes.doc(COURSE).set({ level: 'course', name: NAMES.course, parentId: DEPARTMENT, status: 'published', childCount: 4 });
  }
}

/** A published archive exam (the migration's shape). */
async function seedExam(examId, { title = '2019 VİZE', kind = 'JPG', files = 2, extra = {}, courseId = COURSE } = {}) {
  await db.collection('exams').doc(examId).set({
    title, universityId: EGE, facultyId: FACULTY, departmentId: DEPARTMENT, courseId,
    universityName: NAMES.university, facultyName: NAMES.faculty, departmentName: NAMES.department, courseName: NAMES.course,
    kind, status: 'published', source: 'migration', sortKey: title,
    files: Array.from({ length: files }, (_, index) => ({ storagePath: `imagess/${examId}-${index}.jpg`, order: index })),
    ...extra,
  });
}

/** A draft question as the pipeline writes it. */
function draft(order, overrides = {}) {
  return {
    order, label: String(order), text: `Soru ${order}: $x^2$ türevini al.`, speech: `Soru ${order}: x kare türevini al.`,
    choices: [{ label: 'A', text: '$2x$' }, { label: 'B', text: '$x$' }],
    figureBoxes: [], hasFigure: false, figures: [],
    answer: { text: '$2x$', choice: 'A' }, solution: ['Kuvvet kuralı.'], topics: ['turev'], difficulty: 1,
    confidence: 0.9, needsReview: false, ...overrides,
  };
}

async function seedDrafts(jobId, count, overrides = () => ({})) {
  for (let order = 1; order <= count; order += 1) {
    await job(jobId).collection('questions').doc(String(order).padStart(3, '0')).set(draft(order, overrides(order)));
  }
}

/** An approved 4.2.0 submission whose job is `ready` with `count` drafts. */
async function seedReadySubmission(id, { count = 2, nodesToCreate = [{ id: COURSE, level: 'course', name: NAMES.course, parentId: DEPARTMENT, childCount: 1 }] } = {}) {
  const examId = `${COURSE}__2024-final`;
  await db.collection('submissions').doc(id).set({
    ownerId: 'ayse', university: NAMES.university, faculty: NAMES.faculty, department: NAMES.department,
    lesson: NAMES.course, exam: '2024 FİNAL', kind: 'PDF', status: 'approved', createdAt: DAY,
    files: [{ storagePath: `pending/ayse/${id}/0.pdf`, order: 0 }], conversionProvider: 'gemini',
    publishPlan: {
      examId, universityId: EGE, facultyId: FACULTY, departmentId: DEPARTMENT, courseId: COURSE,
      nodesToCreate, childCountIncrements: [DEPARTMENT],
      exam: {
        title: '2024 FİNAL', universityId: EGE, facultyId: FACULTY, departmentId: DEPARTMENT, courseId: COURSE,
        universityName: NAMES.university, facultyName: NAMES.faculty, departmentName: NAMES.department, courseName: NAMES.course,
        kind: 'PDF', files: [{ storagePath: 'pdfs/copied.pdf', order: 0 }], status: 'published', source: 'submission',
        isLocked: false, coinCost: 0, counts: { views: 0, downloads: 0, unlocks: 0 }, sortKey: '2024 FİNAL',
      },
    },
  });
  await job(`sub-${id}`).set({
    source: { type: 'submission', submissionId: id }, status: 'ready', kind: 'PDF', attempts: 1,
    model: { provider: 'gemini', id: 'gemini-pro' }, files: [{ storagePath: 'pdfs/copied.pdf', order: 0 }],
  });
  await seedDrafts(`sub-${id}`, count, (order) => (order === 2
    ? { figures: [{ storagePath: `questionFigures/sub-${id}/002-1.jpg`, width: 400, height: 300 }], hasFigure: true }
    : {}));
  return { examId, jobId: `sub-${id}` };
}

// --- Admin gate ---------------------------------------------------------------------------------------------------

describe('admin gate', () => {
  test('every callable refuses a caller without the admin claim before touching a dependency', async () => {
    const handlers = [
      admin.requestExamConversionHandler, admin.requestBulkConversionHandler, admin.regenerateExamConversionHandler,
      admin.regenerateDraftQuestionHandler, admin.publishExamConversionHandler, admin.discardExamConversionHandler,
      admin.updatePublishedQuestionHandler, admin.regeneratePublishedQuestionHandler,
    ];
    assert.equal(handlers.length, schema.CALLABLES.length);
    for (const handler of handlers) {
      for (const auth of [null, { uid: 'alice', token: { phone_number: '+905551112233' } }, { uid: 'm', token: { admin: 'true' } }]) {
        await assert.rejects(handler({}, { auth, data: { jobId: 'sub-x', provider: 'claude' } }), { code: 'permission-denied' });
      }
    }
    // The deployed functions are wired to the same handlers.
    for (const name of schema.CALLABLES) {
      await assert.rejects(fns[name].run({ auth: null, data: {} }), { code: 'permission-denied' }, name);
    }
  });
});

// --- Starting jobs ------------------------------------------------------------------------------------------------

describe('requestExamConversion', () => {
  test('creates the legacy job with the provider and enqueues it once; an active job is returned as is', async () => {
    await seedExam('e1');
    const queue = fakeQueue();
    const deps = depsWith({ queue });
    assert.deepEqual(await admin.requestExamConversionHandler(deps, asAdmin({ examId: 'e1', provider: 'claude' })), {
      jobId: 'exam-e1', status: 'queued',
    });
    const created = await getData(job('exam-e1'));
    assert.deepEqual(created.source, { type: 'legacy', examId: 'e1' });
    assert.deepEqual(created.model, { provider: 'claude', id: null });
    assert.equal(created.requestedBy, 'admin-1');
    assert.equal(created.kind, 'JPG');
    assert.equal(created.files.length, 2);
    assert.deepEqual(created.placement.names, [...Object.values(NAMES), '2019 VİZE']);
    // What the review screen reads: the original pages and the suggested subject (none exists yet → from the name).
    assert.deepEqual(created.files, [{ storagePath: 'imagess/e1-0.jpg', order: 0 }, { storagePath: 'imagess/e1-1.jpg', order: 1 }]);
    assert.equal(created.placement.subjectId, publish.subjectKey(NAMES.course));
    assert.equal(created.placement.subjectName, NAMES.course);
    assert.deepEqual(queue.tasks, [{ jobId: 'exam-e1' }]);

    // Pressing again while it runs does nothing.
    await job('exam-e1').update({ status: 'processing' });
    assert.deepEqual(await admin.requestExamConversionHandler(deps, asAdmin({ examId: 'e1', provider: 'gemini' })), {
      jobId: 'exam-e1', status: 'processing',
    });
    assert.equal(queue.tasks.length, 1);

    // A failed job is restarted with the new provider.
    await job('exam-e1').update({ status: 'failed', attempts: 3, error: 'model timeout' });
    await job('exam-e1').collection('questions').doc('001').set(draft(1));
    assert.equal((await admin.requestExamConversionHandler(deps, asAdmin({ examId: 'e1', provider: 'gemini' }))).status, 'queued');
    const restarted = await getData(job('exam-e1'));
    assert.equal(restarted.attempts, 0);
    assert.equal(restarted.error, null);
    assert.deepEqual(restarted.model, { provider: 'gemini', id: null });
    assert.equal((await job('exam-e1').collection('questions').get()).size, 0);
    assert.equal(queue.tasks.length, 2);
  });

  test('a provider-less waiting job (4.1.0 approval) is started; bad input and unknown exams are refused', async () => {
    await seedExam('e2');
    await job('exam-e2').set({ source: { type: 'legacy', examId: 'e2' }, status: 'queued', model: null, attempts: 0 });
    const queue = fakeQueue();
    const deps = depsWith({ queue });
    assert.equal((await admin.requestExamConversionHandler(deps, asAdmin({ examId: 'e2', provider: 'claude' }))).status, 'queued');
    assert.deepEqual(queue.tasks, [{ jobId: 'exam-e2' }]);

    await assert.rejects(admin.requestExamConversionHandler(deps, asAdmin({ examId: 'e2' })), { code: 'invalid-argument' });
    await assert.rejects(admin.requestExamConversionHandler(deps, asAdmin({ examId: 'e2', provider: 'gpt' })), { code: 'invalid-argument' });
    await assert.rejects(admin.requestExamConversionHandler(deps, asAdmin({ examId: 'a/b', provider: 'claude' })), { code: 'invalid-argument' });
    await assert.rejects(admin.requestExamConversionHandler(deps, asAdmin({ examId: 'nope', provider: 'claude' })), { code: 'not-found' });
  });

  test('an already structured exam reports its job as published', async () => {
    await seedExam('e3', { extra: { format: 'structured', conversionJobId: 'sub-s9' } });
    assert.deepEqual(await admin.requestExamConversionHandler(depsWith(), asAdmin({ examId: 'e3', provider: 'claude' })), {
      jobId: 'sub-s9', status: 'published',
    });
  });

  test('a failed enqueue leaves the job restartable', async () => {
    await seedExam('e4');
    const deps = { ...depsWith(), enqueueConversion: async () => { throw new Error('no queue'); } };
    await assert.rejects(admin.requestExamConversionHandler(deps, asAdmin({ examId: 'e4', provider: 'claude' })), { code: 'unavailable' });
    assert.match((await getData(job('exam-e4'))).error, /^enqueue: no queue/);
    const queue = fakeQueue();
    assert.equal((await admin.requestExamConversionHandler(depsWith({ queue }), asAdmin({ examId: 'e4', provider: 'claude' }))).status, 'queued');
    assert.equal((await getData(job('exam-e4'))).error, null);
    assert.equal(queue.tasks.length, 1);
  });
});

describe('requestBulkConversion', () => {
  beforeEach(async () => {
    await seedExam('b-jpg', { files: 3 }); // 3 pages
    await seedExam('b-pdf', { kind: 'PDF', files: 2 }); // 2 × 4 estimated pages
    await seedExam('b-waiting', { files: 1 }); // 1 page, provider-less job
    await job('exam-b-waiting').set({ source: { type: 'legacy', examId: 'b-waiting' }, status: 'queued', model: null });
    await seedExam('b-structured', { extra: { format: 'structured' } });
    await seedExam('b-ready');
    await job('exam-b-ready').set({ source: { type: 'legacy', examId: 'b-ready' }, status: 'ready', model: { provider: 'claude' } });
    await seedExam('b-failed');
    await job('exam-b-failed').set({ source: { type: 'legacy', examId: 'b-failed' }, status: 'failed', model: { provider: 'claude' } });
    await seedExam('b-other-course', { courseId: `${DEPARTMENT}__statik` });
    await seedExam('b-unpublished', { extra: { status: 'draft' } });
  });

  test('a dry run estimates the untouched exams of a course and starts nothing', async () => {
    const queue = fakeQueue();
    const result = await admin.requestBulkConversionHandler(depsWith({ queue }), asAdmin({ courseId: COURSE, provider: 'claude' }));
    assert.deepEqual(result, { examCount: 3, estimatedCostUsd: Math.round(12 * admin.ESTIMATED_COST_PER_PAGE_USD.claude * 100) / 100, jobIds: [] });
    assert.equal(queue.tasks.length, 0);
    assert.equal((await job('exam-b-jpg').get()).exists, false);

    const department = await admin.requestBulkConversionHandler(depsWith({ queue }), asAdmin({ departmentId: DEPARTMENT, provider: 'gemini', dryRun: true }));
    assert.equal(department.examCount, 4); // + the other course's exam
  });

  test('dryRun: false queues them once; a repeated request finds nothing new', async () => {
    const queue = fakeQueue();
    const deps = depsWith({ queue });
    const result = await admin.requestBulkConversionHandler(deps, asAdmin({ courseId: COURSE, provider: 'gemini', dryRun: false }));
    assert.equal(result.examCount, 3);
    assert.deepEqual(result.jobIds.sort(), ['exam-b-jpg', 'exam-b-pdf', 'exam-b-waiting']);
    assert.deepEqual(queue.tasks.map(({ jobId }) => jobId).sort(), result.jobIds);
    assert.deepEqual((await getData(job('exam-b-waiting'))).model, { provider: 'gemini', id: null });
    assert.equal((await getData(job('exam-b-ready'))).status, 'ready');
    assert.equal((await getData(job('exam-b-failed'))).status, 'failed');

    assert.deepEqual(await admin.requestBulkConversionHandler(deps, asAdmin({ courseId: COURSE, provider: 'gemini', dryRun: false })), {
      examCount: 0, estimatedCostUsd: 0, jobIds: [],
    });
  });

  test('exactly one scope and a provider are required', async () => {
    const deps = depsWith();
    await assert.rejects(admin.requestBulkConversionHandler(deps, asAdmin({ provider: 'claude' })), { code: 'invalid-argument' });
    await assert.rejects(
      admin.requestBulkConversionHandler(deps, asAdmin({ courseId: COURSE, departmentId: DEPARTMENT, provider: 'claude' })),
      { code: 'invalid-argument' },
    );
    await assert.rejects(admin.requestBulkConversionHandler(deps, asAdmin({ courseId: COURSE })), { code: 'invalid-argument' });
  });
});

describe('regenerateExamConversion and regenerateDraftQuestion', () => {
  test('a ready job is re-run from scratch with the new provider; running, published and discarded ones are refused', async () => {
    await job('exam-r1').set({ source: { type: 'legacy', examId: 'r1' }, status: 'ready', attempts: 1, model: { provider: 'claude', id: 'x' } });
    await seedDrafts('exam-r1', 3);
    const queue = fakeQueue();
    const deps = depsWith({ queue });
    assert.deepEqual(await admin.regenerateExamConversionHandler(deps, asAdmin({ jobId: 'exam-r1', provider: 'gemini' })), { status: 'queued' });
    assert.deepEqual((await getData(job('exam-r1'))).model, { provider: 'gemini', id: null });
    assert.equal((await job('exam-r1').collection('questions').get()).size, 0);
    assert.deepEqual(queue.tasks, [{ jobId: 'exam-r1' }]);

    for (const status of ['queued', 'processing', 'published', 'discarded']) {
      await job('exam-r1').update({ status, model: { provider: 'claude', id: null }, error: null });
      await assert.rejects(admin.regenerateExamConversionHandler(deps, asAdmin({ jobId: 'exam-r1', provider: 'claude' })), { code: 'failed-precondition' }, status);
    }
    await assert.rejects(admin.regenerateExamConversionHandler(deps, asAdmin({ jobId: 'exam-none', provider: 'claude' })), { code: 'not-found' });
    await assert.rejects(admin.regenerateExamConversionHandler(deps, asAdmin({ jobId: 'bad', provider: 'claude' })), { code: 'invalid-argument' });
    assert.equal(queue.tasks.length, 1);
  });

  test('one draft question of a ready job is queued; the job stays ready', async () => {
    await job('exam-r2').set({ source: { type: 'legacy', examId: 'r2' }, status: 'ready' });
    await seedDrafts('exam-r2', 2);
    const queue = fakeQueue();
    const deps = depsWith({ queue });
    assert.deepEqual(await admin.regenerateDraftQuestionHandler(deps, asAdmin({ jobId: 'exam-r2', order: 2, provider: 'claude' })), { status: 'queued' });
    assert.deepEqual(queue.tasks, [{ jobId: 'exam-r2', order: 2, provider: 'claude', target: 'draft' }]);
    assert.equal((await getData(job('exam-r2'))).status, 'ready');

    await assert.rejects(admin.regenerateDraftQuestionHandler(deps, asAdmin({ jobId: 'exam-r2', order: 7, provider: 'claude' })), { code: 'not-found' });
    await assert.rejects(admin.regenerateDraftQuestionHandler(deps, asAdmin({ jobId: 'exam-r2', order: 0, provider: 'claude' })), { code: 'invalid-argument' });
    await job('exam-r2').update({ status: 'processing' });
    await assert.rejects(admin.regenerateDraftQuestionHandler(deps, asAdmin({ jobId: 'exam-r2', order: 1, provider: 'claude' })), { code: 'failed-precondition' });
  });
});

// --- Publishing ---------------------------------------------------------------------------------------------------

describe('publishExamConversion: submission (second approval)', () => {
  test('executes the plan, writes the questions, pools and subject, and notifies the department', async () => {
    await seedCatalog({ course: false });
    const { examId, jobId } = await seedReadySubmission('s1');

    const result = await admin.publishExamConversionHandler(depsWith(), asAdmin({ jobId }));
    assert.deepEqual(result, { examId, questionCount: 2 });

    // Catalog: the new course is created under the existing department, whose childCount grows by one.
    const course = await getData(db.collection('catalogNodes').doc(COURSE));
    assert.equal(course.level, 'course');
    assert.equal(course.name, NAMES.course);
    assert.equal(course.parentId, DEPARTMENT);
    assert.equal(course.childCount, 1);
    assert.equal(course.subjectId, 'algoritmalar');
    assert.equal((await getData(db.collection('catalogNodes').doc(DEPARTMENT))).childCount, 3);
    assert.equal((await getData(db.collection('catalogNodes').doc(FACULTY))).childCount, 1);

    // The exam keeps its files (old clients) and is marked structured.
    const exam = await getData(db.collection('exams').doc(examId));
    assert.equal(exam.status, 'published');
    assert.equal(exam.format, 'structured');
    assert.equal(exam.questionCount, 2);
    assert.equal(exam.conversionJobId, jobId);
    assert.deepEqual(exam.files, [{ storagePath: 'pdfs/copied.pdf', order: 0 }]);
    assert.equal(exam.structuredAt.toMillis(), DAY.getTime());

    // Published questions: the Ek A shape with denormalised keys; review-only fields left out.
    const first = await getData(db.collection('questions').doc(`${examId}-001`));
    assert.equal(first.schemaVersion, schema.QUESTION_SCHEMA_VERSION);
    assert.equal(first.examId, examId);
    assert.equal(first.order, 1);
    assert.equal(first.subjectId, 'algoritmalar');
    assert.equal(first.courseId, COURSE);
    assert.equal(first.universityId, EGE);
    assert.equal(first.facultyId, FACULTY);
    assert.equal(first.departmentId, DEPARTMENT);
    assert.equal(first.examType, 'final');
    assert.equal(first.year, 2024);
    assert.deepEqual(first.answer, { text: '$2x$', choice: 'A' });
    assert.equal(first.hasFigure, false);
    for (const field of ['confidence', 'needsReview', 'figureBoxes']) assert.equal(field in first, false, field);
    const second = await getData(db.collection('questions').doc(`${examId}-002`));
    assert.deepEqual(second.figures, [{ storagePath: `questionFigures/${jobId}/002-1.jpg`, width: 400, height: 300 }]);
    assert.equal(second.hasFigure, true);

    // Pools: country, university and course scopes.
    const ids = [`${examId}-001`, `${examId}-002`];
    for (const scope of [{ scope: 'tr' }, { scope: 'university', universityId: EGE }, { scope: 'course', courseId: COURSE }]) {
      const pool = await getData(db.collection('questionPools').doc(schema.questionPoolId({ subjectId: 'algoritmalar', examType: 'final', ...scope })));
      assert.deepEqual(pool.ids, ids, scope.scope);
      assert.equal(pool.count, 2);
      assert.equal(pool.part, 1);
    }

    const subject = await getData(db.collection('subjects').doc('algoritmalar'));
    assert.equal(subject.name, NAMES.course);
    assert.deepEqual(subject.aliases, ['algoritmalar']);

    const finished = await getData(job(jobId));
    assert.equal(finished.status, 'published');
    assert.equal(finished.reviewedBy, 'admin-1');
    assert.equal(finished.publishedExamId, examId);
    assert.equal((await getData(db.collection('submissions').doc('s1'))).publishedExamId, examId);

    // The department notice moved here: members hear about it, the uploader does not.
    const notice = await getData(db.collection('notifications').doc('auto-newexam-s1'));
    assert.equal(notice.trigger, 'newExam');
    assert.equal(notice.status, 'sent');
    assert.equal(notice.action.examId, examId);
    assert.equal((await db.collection('users').doc('can').collection('inbox').doc('auto-newexam-s1').get()).exists, true);
    assert.equal((await db.collection('users').doc('ayse').collection('inbox').doc('auto-newexam-s1').get()).exists, false);

    // Idempotent: a second call reports the same result and changes nothing.
    assert.deepEqual(await admin.publishExamConversionHandler(depsWith(), asAdmin({ jobId })), result);
    assert.equal((await getData(db.collection('catalogNodes').doc(DEPARTMENT))).childCount, 3);
  });

  test('a plan made stale by another publish still keeps childCount right', async () => {
    // The plan wanted to create the course, but it exists now: the course is bumped instead of the department.
    await seedCatalog({ course: true });
    const { jobId } = await seedReadySubmission('s2', { count: 1 });
    await admin.publishExamConversionHandler(depsWith(), asAdmin({ jobId }));
    assert.equal((await getData(db.collection('catalogNodes').doc(COURSE))).childCount, 5);
    assert.equal((await getData(db.collection('catalogNodes').doc(DEPARTMENT))).childCount, 2);
  });

  test('a whole new university chain is created; an exam that already exists or a job not ready is refused', async () => {
    const { examId, jobId } = await seedReadySubmission('s3', { count: 1, nodesToCreate: [] });
    await admin.publishExamConversionHandler(depsWith(), asAdmin({ jobId }));
    for (const [id, level, parentId] of [[EGE, 'university', ''], [FACULTY, 'faculty', EGE], [DEPARTMENT, 'department', FACULTY], [COURSE, 'course', DEPARTMENT]]) {
      const node = await getData(db.collection('catalogNodes').doc(id));
      assert.equal(node.level, level);
      assert.equal(node.parentId, parentId);
      assert.equal(node.childCount, 1);
      assert.equal(node.status, 'published');
    }
    assert.equal((await getData(db.collection('exams').doc(examId))).format, 'structured');

    const again = await seedReadySubmission('s4', { count: 1 });
    await assert.rejects(admin.publishExamConversionHandler(depsWith(), asAdmin({ jobId: again.jobId })), { code: 'already-exists' });
    assert.equal((await getData(job(again.jobId))).status, 'ready');

    await job(again.jobId).update({ status: 'processing' });
    await assert.rejects(admin.publishExamConversionHandler(depsWith(), asAdmin({ jobId: again.jobId })), { code: 'failed-precondition' });
  });
});

describe('publishExamConversion: legacy exam and subjects', () => {
  test('marks the existing exam structured, reuses a subject by alias and drops stale questions from the pools', async () => {
    await seedCatalog();
    await seedExam('L1', { title: '2018-2019 BÜTÜNLEME' });
    await db.collection('subjects').doc('algoritma-ve-programlama').set({ name: 'Algoritma ve Programlama', aliases: ['algoritmalar'] });
    // A question from an earlier structure that the new draft no longer has.
    const staleKeys = { subjectId: 'algoritma-ve-programlama', examType: 'butunleme', universityId: EGE, courseId: COURSE };
    await db.collection('questions').doc('L1-009').set({ examId: 'L1', order: 9, ...staleKeys });
    const trPool = db.collection('questionPools').doc(schema.questionPoolId({ ...staleKeys, scope: 'tr' }));
    await trPool.set({ ids: ['other-001', 'L1-009'], count: 2 });
    await job('exam-L1').set({ source: { type: 'legacy', examId: 'L1' }, status: 'ready' });
    await seedDrafts('exam-L1', 1);

    assert.deepEqual(await admin.publishExamConversionHandler(depsWith(), asAdmin({ jobId: 'exam-L1' })), { examId: 'L1', questionCount: 1 });
    const exam = await getData(db.collection('exams').doc('L1'));
    assert.equal(exam.format, 'structured');
    assert.equal(exam.files.length, 2);
    assert.equal((await db.collection('questions').doc('L1-009').get()).exists, false);
    const question = await getData(db.collection('questions').doc('L1-001'));
    assert.equal(question.subjectId, 'algoritma-ve-programlama');
    assert.equal(question.examType, 'butunleme');
    assert.equal(question.year, 2018);
    assert.deepEqual((await getData(trPool)).ids, ['other-001', 'L1-001']);
    assert.equal((await getData(db.collection('catalogNodes').doc(COURSE))).subjectId, 'algoritma-ve-programlama');
    assert.equal((await db.collection('subjects').doc('algoritmalar').get()).exists, false);
    // A legacy exam was public already: no department notice.
    assert.equal((await db.collection('notifications').get()).size, 0);
  });

  test('the admin can pick an existing subject or open a new one; a missing subject is refused', async () => {
    await seedCatalog();
    await db.collection('subjects').doc('veri-yapilari').set({ name: 'Veri Yapıları', aliases: ['veri-yapilari'] });
    for (const id of ['L2', 'L3', 'L4']) {
      await seedExam(id, { title: '2020 VİZE' });
      await job(`exam-${id}`).set({ source: { type: 'legacy', examId: id }, status: 'ready' });
      await seedDrafts(`exam-${id}`, 1);
    }
    const deps = depsWith();
    await assert.rejects(admin.publishExamConversionHandler(deps, asAdmin({ jobId: 'exam-L2', subjectId: 'yok' })), { code: 'invalid-argument' });
    await assert.rejects(
      admin.publishExamConversionHandler(deps, asAdmin({ jobId: 'exam-L2', subjectId: 'veri-yapilari', newSubjectName: 'X' })),
      { code: 'invalid-argument' },
    );

    await admin.publishExamConversionHandler(deps, asAdmin({ jobId: 'exam-L2', subjectId: 'veri-yapilari' }));
    assert.equal((await getData(db.collection('questions').doc('L2-001'))).subjectId, 'veri-yapilari');
    assert.deepEqual((await getData(db.collection('subjects').doc('veri-yapilari'))).aliases, ['veri-yapilari', 'algoritmalar']);
    assert.equal((await getData(db.collection('catalogNodes').doc(COURSE))).subjectId, 'veri-yapilari');

    await admin.publishExamConversionHandler(deps, asAdmin({ jobId: 'exam-L3', newSubjectName: 'Algoritma Analizi' }));
    assert.equal((await getData(db.collection('questions').doc('L3-001'))).subjectId, 'algoritma-analizi');
    const created = await getData(db.collection('subjects').doc('algoritma-analizi'));
    assert.equal(created.name, 'Algoritma Analizi');
    assert.deepEqual(created.aliases, ['algoritma-analizi', 'algoritmalar']);

    // Without an override the course node's subject is used.
    await admin.publishExamConversionHandler(deps, asAdmin({ jobId: 'exam-L4' }));
    assert.equal((await getData(db.collection('questions').doc('L4-001'))).subjectId, 'algoritma-analizi');
  });

  test('a draft without text or answer cannot be published', async () => {
    await seedCatalog();
    await seedExam('L5');
    await job('exam-L5').set({ source: { type: 'legacy', examId: 'L5' }, status: 'ready' });
    await seedDrafts('exam-L5', 2, (order) => (order === 2 ? { answer: { text: ' ' } } : {}));
    await assert.rejects(admin.publishExamConversionHandler(depsWith(), asAdmin({ jobId: 'exam-L5' })), { code: 'failed-precondition' });
    assert.equal((await db.collection('questions').get()).size, 0);
  });
});

describe('question pools: parts', () => {
  test('a full part continues in __p2; an emptied last part is deleted', () => {
    const writes = [];
    const transaction = {
      set: (ref, data) => writes.push(['set', ref.id, data.ids]),
      delete: (ref) => writes.push(['delete', ref.id]),
    };
    const spec = { subjectId: 'fizik', examType: 'vize', scope: 'tr' };
    const full = Array.from({ length: publish.POOL_PART_LIMIT }, (_, index) => `q${index}`);
    const ref = (part) => db.collection('questionPools').doc(schema.questionPoolId({ ...spec, part }));
    const pools = new Map([['fizik__vize__tr', {
      spec, add: new Set(['new-1', 'q5']), remove: new Set(),
      parts: [{ ref: ref(1), part: 1, ids: full }, { ref: ref(2), part: 2, ids: null }],
    }]]);
    publish.writePools(transaction, db, pools, null);
    assert.deepEqual(writes, [['set', 'fizik__vize__tr__p2', ['new-1']]]);

    writes.length = 0;
    const emptied = new Map([['fizik__vize__tr', {
      spec, add: new Set(), remove: new Set(['x']),
      parts: [{ ref: ref(1), part: 1, ids: full }, { ref: ref(2), part: 2, ids: ['x'] }, { ref: ref(3), part: 3, ids: null }],
    }]]);
    publish.writePools(transaction, db, emptied, null);
    assert.deepEqual(writes, [['delete', 'fizik__vize__tr__p2']]);

    assert.deepEqual(publish.poolBases({ subjectId: 'fizik', examType: null, courseId: 'c' }), []);
  });
});

// --- After publishing ---------------------------------------------------------------------------------------------

describe('discard, edit and regenerate published questions, delete', () => {
  test('discardExamConversion ends a ready, queued or failed job; published and running ones are refused', async () => {
    const deps = depsWith();
    for (const status of ['ready', 'queued', 'failed']) {
      await job(`exam-d-${status}`).set({ source: { type: 'legacy', examId: `d-${status}` }, status });
      assert.deepEqual(await admin.discardExamConversionHandler(deps, asAdmin({ jobId: `exam-d-${status}` })), { status: 'discarded' });
      const discarded = await getData(job(`exam-d-${status}`));
      assert.equal(discarded.status, 'discarded');
      assert.equal(discarded.reviewedBy, 'admin-1');
    }
    assert.deepEqual(await admin.discardExamConversionHandler(deps, asAdmin({ jobId: 'exam-d-ready' })), { status: 'discarded' });
    for (const status of ['processing', 'published']) {
      await job(`exam-d-${status}`).set({ source: { type: 'legacy', examId: `d-${status}` }, status });
      await assert.rejects(admin.discardExamConversionHandler(deps, asAdmin({ jobId: `exam-d-${status}` })), { code: 'failed-precondition' });
    }
    await assert.rejects(admin.discardExamConversionHandler(deps, asAdmin({ jobId: 'exam-missing' })), { code: 'not-found' });
  });

  test('a published question is edited in place (draft mirrored) and regenerated under the same id', async () => {
    await seedCatalog({ course: false });
    const { examId, jobId } = await seedReadySubmission('s5');
    await admin.publishExamConversionHandler(depsWith(), asAdmin({ jobId }));
    const questionId = `${examId}-001`;
    const later = new Date(DAY.getTime() + 60_000);

    const result = await admin.updatePublishedQuestionHandler(depsWith({ now: later }), asAdmin({
      questionId, text: '  Düzeltilmiş soru  ', answer: { text: '$x$', choice: 'B' },
    }));
    assert.deepEqual(result, { updatedAt: later.getTime() });
    const edited = await getData(db.collection('questions').doc(questionId));
    assert.equal(edited.text, 'Düzeltilmiş soru');
    assert.deepEqual(edited.answer, { text: '$x$', choice: 'B' });
    assert.equal(edited.updatedAt.toMillis(), later.getTime());
    assert.equal(edited.subjectId, 'algoritmalar');
    const mirrored = await getData(job(jobId).collection('questions').doc('001'));
    assert.equal(mirrored.text, 'Düzeltilmiş soru');
    assert.equal(mirrored.editedBy, 'admin-1');

    const deps = depsWith();
    await assert.rejects(admin.updatePublishedQuestionHandler(deps, asAdmin({ questionId })), { code: 'invalid-argument' });
    await assert.rejects(admin.updatePublishedQuestionHandler(deps, asAdmin({ questionId, answer: { text: 'x', choice: 'Z' } })), { code: 'invalid-argument' });
    await assert.rejects(admin.updatePublishedQuestionHandler(deps, asAdmin({ questionId, text: '' })), { code: 'invalid-argument' });
    await assert.rejects(admin.updatePublishedQuestionHandler(deps, asAdmin({ questionId: `${examId}-099`, text: 'x' })), { code: 'not-found' });

    // Regenerate: the pipeline gets the published target, rewrites the draft and puts it live with publishDraftQuestion.
    const queue = fakeQueue();
    assert.deepEqual(await admin.regeneratePublishedQuestionHandler(depsWith({ queue }), asAdmin({ questionId, provider: 'gemini' })), { status: 'queued' });
    assert.deepEqual(queue.tasks, [{ jobId, order: 1, provider: 'gemini', target: 'published' }]);
    await job(jobId).collection('questions').doc('001').set(draft(1, { text: 'Yeniden üretilmiş soru' }));
    assert.deepEqual(await publish.publishDraftQuestion(depsWith({ now: later }), { jobId, order: 1 }), { questionId });
    const regenerated = await getData(db.collection('questions').doc(questionId));
    assert.equal(regenerated.text, 'Yeniden üretilmiş soru');
    assert.equal(regenerated.examType, 'final');
    assert.equal(regenerated.subjectId, 'algoritmalar');

    await assert.rejects(admin.regeneratePublishedQuestionHandler(deps, asAdmin({ questionId: 'bad', provider: 'gemini' })), { code: 'invalid-argument' });
  });

  test('deleteStructuredExamData removes questions, pool entries, figures and the job', async () => {
    await seedCatalog({ course: false });
    const { examId, jobId } = await seedReadySubmission('s6');
    await admin.publishExamConversionHandler(depsWith(), asAdmin({ jobId }));
    const bucket = fakeBucket();

    const result = await publish.deleteStructuredExamData(depsWith({ bucket }), examId);
    assert.equal(result.questions, 2);
    assert.deepEqual(result.jobs.sort(), [`exam-${examId}`, jobId].sort());
    assert.equal((await db.collection('questions').where('examId', '==', examId).get()).size, 0);
    assert.equal((await db.collection('questionPools').get()).size, 0);
    assert.equal((await job(jobId).get()).exists, false);
    assert.equal((await job(jobId).collection('questions').get()).size, 0);
    assert.ok(bucket.deleted.includes(`questionFigures/${jobId}/`));
  });
});

describe('job creation: the suggested subject', () => {
  test('a job suggests the subject an automatic publish would pick (alias match; the course node wins)', async () => {
    await seedCatalog();
    await seedExam('e1');
    await db.collection('subjects').doc('algoritma-ve-programlama').set({ name: 'Algoritma ve Programlama', aliases: ['algoritmalar'] });
    await admin.requestExamConversionHandler(depsWith(), asAdmin({ examId: 'e1', provider: 'gemini' }));
    const byAlias = (await getData(job('exam-e1'))).placement;
    assert.equal(byAlias.subjectId, 'algoritma-ve-programlama');
    assert.equal(byAlias.subjectName, 'Algoritma ve Programlama');

    await db.collection('subjects').doc('ayrik').set({ name: 'Ayrık Matematik', aliases: [] });
    await db.collection('catalogNodes').doc(COURSE).update({ subjectId: 'ayrik' });
    await seedExam('e2', { title: '2020 FİNAL' });
    await admin.requestExamConversionHandler(depsWith(), asAdmin({ examId: 'e2', provider: 'gemini' }));
    const byNode = (await getData(job('exam-e2'))).placement;
    assert.deepEqual([byNode.subjectId, byNode.subjectName], ['ayrik', 'Ayrık Matematik']);
  });
});

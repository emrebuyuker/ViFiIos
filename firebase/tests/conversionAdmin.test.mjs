// The structured-exam admin callables and publishing (`functions/conversions/{admin,publish,jobs}.js`) against the
// Firestore and Realtime Database emulators: the admin gate, starting / re-running jobs (a fake task queue records
// what would be enqueued), the bulk estimate, the second approval's publish transaction (catalog nodes, exam,
// questions, pools, subjects, department notice), discarding, editing and regenerating published questions, and the
// exam-deletion cleanup; the owner decisions of 13 Nov 2026: duplicates replace the existing exam (K22), a discarded
// submission's copies are removed (K20), a subject change moves the whole course (K21), and publishing sends the
// uploader nothing (K19); 14 Nov 2026: a converted exam's title comes from the exam-name list (K28, K29). FCM and Storage are fakes; nothing leaves this machine and no AI is called.

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
let subjects;
let schema;

before(async () => {
  assertLocalEmulators('FIRESTORE_EMULATOR_HOST', 'FIREBASE_DATABASE_EMULATOR_HOST');
  mock.method(console, 'error', () => {});
  mock.method(console, 'warn', () => {});
  fns = await import('../functions/index.js');
  admin = await import('../functions/conversions/admin.js');
  publish = await import('../functions/conversions/publish.js');
  subjects = await import('../functions/conversions/subjectsAdmin.js');
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

/** Records prefix deletions (`deleted`) and single-file deletions (`removedFiles`). */
function fakeBucket() {
  const deleted = [];
  const removedFiles = [];
  return {
    deleted,
    removedFiles,
    async deleteFiles({ prefix }) { deleted.push(prefix); },
    file: (name) => ({ async delete() { removedFiles.push(name); } }),
  };
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
async function seedReadySubmission(id, {
  count = 2,
  nodesToCreate = [{ id: COURSE, level: 'course', name: NAMES.course, parentId: DEPARTMENT, childCount: 1 }],
  title = '2024 FİNAL',
} = {}) {
  const examId = `${COURSE}__2024-final`;
  await db.collection('submissions').doc(id).set({
    ownerId: 'ayse', university: NAMES.university, faculty: NAMES.faculty, department: NAMES.department,
    lesson: NAMES.course, exam: title, kind: 'PDF', status: 'approved', createdAt: DAY,
    files: [{ storagePath: `pending/ayse/${id}/0.pdf`, order: 0 }], conversionProvider: 'gemini',
    publishPlan: {
      examId, universityId: EGE, facultyId: FACULTY, departmentId: DEPARTMENT, courseId: COURSE,
      nodesToCreate, childCountIncrements: [DEPARTMENT],
      exam: {
        title, universityId: EGE, facultyId: FACULTY, departmentId: DEPARTMENT, courseId: COURSE,
        universityName: NAMES.university, facultyName: NAMES.faculty, departmentName: NAMES.department, courseName: NAMES.course,
        kind: 'PDF', files: [{ storagePath: 'pdfs/copied.pdf', order: 0 }], status: 'published', source: 'submission',
        isLocked: false, coinCost: 0, counts: { views: 0, downloads: 0, unlocks: 0 }, sortKey: title,
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

/**
 * An approved DUPLICATE submission (K22, `publishPlan.mode: 'replace'`) of the existing exam `examId`, its job
 * `ready` with `count` drafts; the first approval copied `pdfs/new-<id>.pdf`.
 */
async function seedReadyDuplicate(id, examId, { count = 2 } = {}) {
  const files = [{ storagePath: `pdfs/new-${id}.pdf`, order: 0 }];
  await db.collection('submissions').doc(id).set({
    ownerId: 'ayse', university: NAMES.university, faculty: NAMES.faculty, department: NAMES.department,
    lesson: NAMES.course, exam: '2024 FİNAL', kind: 'PDF', status: 'approved', createdAt: DAY, conversionProvider: 'claude',
    files: [{ storagePath: `pending/ayse/${id}/0.pdf`, order: 0 }],
    publishPlan: {
      mode: 'replace', examId, universityId: EGE, facultyId: FACULTY, departmentId: DEPARTMENT, courseId: COURSE,
      nodesToCreate: [], childCountIncrements: [],
      exam: { title: '2024 FİNAL', kind: 'PDF', files, courseName: NAMES.course, status: 'published' },
    },
  });
  await job(`sub-${id}`).set({
    source: { type: 'submission', submissionId: id }, status: 'ready', kind: 'PDF', attempts: 1,
    model: { provider: 'claude', id: 'claude-opus' }, files,
  });
  await seedDrafts(`sub-${id}`, count);
  return { jobId: `sub-${id}`, files };
}

// --- Admin gate ---------------------------------------------------------------------------------------------------

describe('admin gate', () => {
  test('every callable refuses a caller without the admin claim before touching a dependency', async () => {
    const handlers = [
      admin.requestExamConversionHandler, admin.requestBulkConversionHandler, admin.regenerateExamConversionHandler,
      admin.regenerateDraftQuestionHandler, admin.publishExamConversionHandler, admin.discardExamConversionHandler,
      admin.updatePublishedQuestionHandler, admin.regeneratePublishedQuestionHandler,
      subjects.listSubjectsHandler, subjects.setCourseSubjectHandler, subjects.renameSubjectHandler, subjects.mergeSubjectsHandler,
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
    assert.equal(created.placement.originalTitle, '2019 VİZE');
    assert.equal(created.placement.suggestedTitle, '2019 VİZE');
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
    assert.equal(exam.title, '2024 FİNAL');
    assert.equal(exam.sortKey, '2024 FİNAL');

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
    // K19: publishing sends the uploader no second notice (their only one is the first approval's coins notice).
    assert.equal((await db.collection('notifications').where('audience.uid', '==', 'ayse').get()).size, 0);
    assert.equal((await db.collection('users').doc('ayse').collection('inbox').get()).size, 0);

    // Idempotent: a second call reports the same result and changes nothing.
    assert.deepEqual(await admin.publishExamConversionHandler(depsWith(), asAdmin({ jobId })), result);
    assert.equal((await getData(db.collection('catalogNodes').doc(DEPARTMENT))).childCount, 3);
  });

  test('study material is published with its exam type but joins no practice pool (K27)', async () => {
    await seedCatalog({ course: false });
    const { examId, jobId } = await seedReadySubmission('s-material', { title: '2024 ÇALIŞMA SORULARI' });

    assert.deepEqual(await admin.publishExamConversionHandler(depsWith(), asAdmin({ jobId })), { examId, questionCount: 2 });
    const first = await getData(db.collection('questions').doc(`${examId}-001`));
    assert.equal(first.examType, 'calisma-sorulari');
    assert.equal(first.year, 2024);
    assert.equal((await db.collection('questionPools').get()).size, 0);
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

describe('publishExamConversion: duplicate submission (K22, mode replace)', () => {
  test('a legacy exam becomes structured with the new files; old files go unless another exam lists them', async () => {
    await seedCatalog();
    const examId = `${COURSE}__2024-final`;
    await seedExam(examId, { title: '2024 FİNAL', kind: 'JPG', files: 2 });
    // Another exam still lists the second old page: it must survive.
    await seedExam('other', { files: 0, extra: { files: [{ storagePath: `imagess/${examId}-1.jpg`, order: 3 }] } });
    // The exam's own legacy job, still awaiting review: ended by the replace.
    await job(`exam-${examId}`).set({ source: { type: 'legacy', examId }, status: 'ready' });
    const { jobId, files } = await seedReadyDuplicate('d1', examId);
    const bucket = fakeBucket();

    assert.deepEqual(await admin.publishExamConversionHandler(depsWith({ bucket }), asAdmin({ jobId })), { examId, questionCount: 2 });
    const exam = await getData(db.collection('exams').doc(examId));
    assert.equal(exam.format, 'structured');
    assert.equal(exam.conversionJobId, jobId);
    assert.equal(exam.questionCount, 2);
    assert.deepEqual(exam.files, files);
    assert.equal(exam.kind, 'PDF');
    assert.equal(exam.title, '2024 FİNAL');
    // No second copy, no catalog change.
    assert.equal((await db.collection('exams').where('courseId', '==', COURSE).get()).size, 2);
    assert.equal((await getData(db.collection('catalogNodes').doc(COURSE))).childCount, 4);
    assert.equal((await getData(db.collection('catalogNodes').doc(DEPARTMENT))).childCount, 2);

    assert.equal((await getData(db.collection('questions').doc(`${examId}-002`))).examType, 'final');
    const legacy = await getData(job(`exam-${examId}`));
    assert.deepEqual([legacy.status, legacy.discardReason, legacy.reviewedBy], ['discarded', 'replaced', 'admin-1']);
    assert.equal((await getData(db.collection('submissions').doc('d1'))).publishedExamId, examId);
    assert.equal((await getData(job(jobId))).status, 'published');

    assert.deepEqual(bucket.removedFiles, [`imagess/${examId}-0.jpg`]);
    // A replaced exam is not new: no department notice, and the uploader hears nothing at publish (K19).
    assert.equal((await db.collection('notifications').get()).size, 0);
    assert.equal((await db.collection('users').doc('ayse').collection('inbox').get()).size, 0);
  });

  test('an already structured exam gets its questions replaced; extra old questions and pool entries go', async () => {
    await seedCatalog();
    const examId = `${COURSE}__2024-final`;
    await seedExam(examId, { title: '2024 FİNAL' });
    await job(`exam-${examId}`).set({ source: { type: 'legacy', examId }, status: 'ready' });
    await seedDrafts(`exam-${examId}`, 3);
    await admin.publishExamConversionHandler(depsWith(), asAdmin({ jobId: `exam-${examId}` }));
    const pool = db.collection('questionPools').doc(schema.questionPoolId({ subjectId: 'algoritmalar', examType: 'final', scope: 'tr' }));
    assert.equal((await getData(pool)).count, 3);

    const { jobId } = await seedReadyDuplicate('d2', examId, { count: 2 });
    const bucket = fakeBucket();
    await admin.publishExamConversionHandler(depsWith({ bucket }), asAdmin({ jobId }));
    const ids = (await db.collection('questions').where('examId', '==', examId).get()).docs.map((doc) => doc.id).sort();
    assert.deepEqual(ids, [`${examId}-001`, `${examId}-002`]);
    assert.deepEqual((await getData(pool)).ids, [`${examId}-001`, `${examId}-002`]);
    assert.equal((await getData(db.collection('exams').doc(examId))).conversionJobId, jobId);
    // The previously published job stays published (history); its figures are no longer used.
    assert.equal((await getData(job(`exam-${examId}`))).status, 'published');
    assert.ok(bucket.deleted.includes(`questionFigures/exam-${examId}/`));
    assert.deepEqual(bucket.removedFiles.sort(), [`imagess/${examId}-0.jpg`, `imagess/${examId}-1.jpg`]);

    // Idempotent: publishing again changes nothing.
    assert.deepEqual(await admin.publishExamConversionHandler(depsWith(), asAdmin({ jobId })), { examId, questionCount: 2 });
  });

  test('a replace plan whose exam is gone is refused; a create plan for an existing exam still is', async () => {
    await seedCatalog();
    const { jobId } = await seedReadyDuplicate('d3', `${COURSE}__yok`);
    await assert.rejects(admin.publishExamConversionHandler(depsWith(), asAdmin({ jobId })), { code: 'failed-precondition' });
    assert.equal((await getData(job(jobId))).status, 'ready');
  });
});

describe('discardExamConversion: copies of a submission (K20)', () => {
  test('the first approval\'s copies are deleted unless an exam lists them; legacy jobs delete nothing', async () => {
    await seedCatalog({ course: false });
    const { jobId } = await seedReadySubmission('x1');
    await job(jobId).update({ files: [{ storagePath: 'pdfs/copied.pdf', order: 0 }, { storagePath: 'pdfs/shared.pdf', order: 1 }] });
    await seedExam('lister', { files: 0, extra: { files: [{ storagePath: 'pdfs/shared.pdf', order: 0 }] } });
    const bucket = fakeBucket();
    assert.deepEqual(await admin.discardExamConversionHandler(depsWith({ bucket }), asAdmin({ jobId })), { status: 'discarded' });
    assert.deepEqual(bucket.removedFiles, ['pdfs/copied.pdf']);
    // Coins / the submission stay as they are.
    assert.equal((await getData(db.collection('submissions').doc('x1'))).status, 'approved');

    // Idempotent: a repeated call only repeats the (harmless) cleanup.
    assert.deepEqual(await admin.discardExamConversionHandler(depsWith({ bucket }), asAdmin({ jobId })), { status: 'discarded' });

    const legacyBucket = fakeBucket();
    await seedExam('e9');
    await job('exam-e9').set({ source: { type: 'legacy', examId: 'e9' }, status: 'failed', files: [{ storagePath: 'imagess/e9-0.jpg', order: 0 }] });
    await admin.discardExamConversionHandler(depsWith({ bucket: legacyBucket }), asAdmin({ jobId: 'exam-e9' }));
    assert.deepEqual(legacyBucket.removedFiles, []);
  });

  test('only archive page paths are ever deleted', async () => {
    const files = await import('../functions/conversions/files.js');
    assert.deepEqual(files.archiveFileEntries([
      { storagePath: 'pdfs/a.pdf', order: 1 }, { storagePath: 'pending/u/s/0.pdf' }, { storagePath: 'questionFigures/x/001-1.jpg' },
      { storagePath: 'imagess/b.jpg' }, { storagePath: 'pdfs/a.pdf', order: 2 }, { storagePath: 'imagess/../x.jpg' }, null,
    ]), [{ storagePath: 'pdfs/a.pdf', order: 1 }, { storagePath: 'imagess/b.jpg', order: 0 }]);
  });
});

describe('publishExamConversion: subject change moves the course (K21)', () => {
  test('all published questions of the course and their pool entries move to the new subject', async () => {
    await seedCatalog();
    await seedExam('M1', { title: '2019 VİZE' });
    await seedExam('M2', { title: '2020 VİZE' });
    await seedExam('M3', { title: '2021 VİZE', courseId: `${DEPARTMENT}__statik` }); // another course: untouched
    for (const id of ['M1', 'M2', 'M3']) {
      await job(`exam-${id}`).set({ source: { type: 'legacy', examId: id }, status: 'ready' });
    }
    await seedDrafts('exam-M1', 2);
    await seedDrafts('exam-M2', 1);
    await seedDrafts('exam-M3', 1);
    await admin.publishExamConversionHandler(depsWith(), asAdmin({ jobId: 'exam-M1' }));
    await admin.publishExamConversionHandler(depsWith(), asAdmin({ jobId: 'exam-M3' }));
    assert.equal((await getData(db.collection('questions').doc('M1-001'))).subjectId, 'algoritmalar');
    const oldPool = db.collection('questionPools').doc(schema.questionPoolId({ subjectId: 'algoritmalar', examType: 'vize', scope: 'tr' }));
    assert.deepEqual((await getData(oldPool)).ids, ['M1-001', 'M1-002', 'M3-001']);

    const deps = { ...depsWith(), subjectMoveChunk: 1 };
    await admin.publishExamConversionHandler(deps, asAdmin({ jobId: 'exam-M2', newSubjectName: 'Algoritma Analizi' }));
    for (const id of ['M1-001', 'M1-002', 'M2-001']) {
      assert.equal((await getData(db.collection('questions').doc(id))).subjectId, 'algoritma-analizi', id);
    }
    // The other course's question keeps its subject and its pool entry.
    assert.equal((await getData(db.collection('questions').doc('M3-001'))).subjectId, 'algoritmalar');
    assert.deepEqual((await getData(oldPool)).ids, ['M3-001']);
    for (const scope of [{ scope: 'tr' }, { scope: 'university', universityId: EGE }, { scope: 'course', courseId: COURSE }]) {
      const pool = await getData(db.collection('questionPools').doc(
        schema.questionPoolId({ subjectId: 'algoritma-analizi', examType: 'vize', ...scope }),
      ));
      assert.deepEqual([...pool.ids].sort(), ['M1-001', 'M1-002', 'M2-001'], scope.scope);
    }
    assert.equal((await getData(db.collection('catalogNodes').doc(COURSE))).subjectId, 'algoritma-analizi');
    const move = (await getData(job('exam-M2'))).subjectMove;
    assert.deepEqual([move.status, move.fromSubjectId, move.toSubjectId, move.movedCount], ['done', 'algoritmalar', 'algoritma-analizi', 2]);

    // Resuming (a pending move after a crash) is a no-op for questions already moved.
    await job('exam-M2').update({ 'subjectMove.status': 'pending' });
    await admin.publishExamConversionHandler(deps, asAdmin({ jobId: 'exam-M2' }));
    const resumed = (await getData(job('exam-M2'))).subjectMove;
    assert.deepEqual([resumed.status, resumed.movedCount], ['done', 0]);
    assert.deepEqual([...(await getData(db.collection('questionPools').doc(
      schema.questionPoolId({ subjectId: 'algoritma-analizi', examType: 'vize', scope: 'tr' }),
    ))).ids].sort(), ['M1-001', 'M1-002', 'M2-001']);
  });

  test('publishing with the course\'s current subject moves nothing', async () => {
    await seedCatalog();
    await seedExam('N1');
    await job('exam-N1').set({ source: { type: 'legacy', examId: 'N1' }, status: 'ready' });
    await seedDrafts('exam-N1', 1);
    await admin.publishExamConversionHandler(depsWith(), asAdmin({ jobId: 'exam-N1' }));
    await seedExam('N2', { title: '2021 FİNAL' });
    await job('exam-N2').set({ source: { type: 'legacy', examId: 'N2' }, status: 'ready' });
    await seedDrafts('exam-N2', 1);
    await admin.publishExamConversionHandler(depsWith(), asAdmin({ jobId: 'exam-N2', subjectId: 'algoritmalar' }));
    assert.equal((await getData(job('exam-N2'))).subjectMove, undefined);
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
    // K29: an academic-year range counts as its second year; the exam's title becomes the list title (K28).
    assert.equal(question.year, 2019);
    assert.equal(exam.title, '2019 BÜTÜNLEME');
    assert.equal(exam.sortKey, '2019 BÜTÜNLEME');
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
    // Study materials keep their exam type on the question but join no practice pool (K27).
    assert.deepEqual(publish.poolBases({ subjectId: 'fizik', examType: 'calisma-sorulari', universityId: 'u', courseId: 'c' }), []);
    assert.equal(publish.poolBases({ subjectId: 'fizik', examType: 'ek-sinav', universityId: 'u', courseId: 'c' }).length, 3);
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

  test('onExamDeleted: after the exam document is gone it removes questions, pools, figures and the job; plain exam and re-run are no-ops', async () => {
    await seedCatalog({ course: false });
    const { examId, jobId } = await seedReadySubmission('s7');
    await admin.publishExamConversionHandler(depsWith(), asAdmin({ jobId }));
    await seedExam('plain1');
    const bucket = fakeBucket();
    const event = (id) => ({ params: { examId: id } });

    await db.collection('exams').doc(examId).delete();
    const result = await publish.onExamDeletedHandler(depsWith({ bucket }), event(examId));
    assert.equal(result.questions, 2);
    assert.ok(result.jobs.includes(jobId));
    assert.equal((await db.collection('questions').where('examId', '==', examId).get()).size, 0);
    assert.equal((await db.collection('questionPools').get()).size, 0);
    assert.equal((await job(jobId).get()).exists, false);
    assert.ok(bucket.deleted.includes(`questionFigures/${jobId}/`));

    const again = await publish.onExamDeletedHandler(depsWith({ bucket: fakeBucket() }), event(examId));
    assert.equal(again.questions, 0);
    const plain = await publish.onExamDeletedHandler(depsWith({ bucket: fakeBucket() }), event('plain1'));
    assert.equal(plain.questions, 0);
    assert.equal(await publish.onExamDeletedHandler(depsWith(), event('bad/id')), null);
    assert.equal(typeof fns.onExamDeleted, 'function');
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

describe('exam title from the list (K28)', () => {
  /** A ready legacy job for `examId` (created by the real job builder, so its placement carries the suggestion). */
  async function seedReadyLegacy(examId, title, { count = 1 } = {}) {
    await seedExam(examId, { title });
    const exam = await getData(db.collection('exams').doc(examId));
    const { legacyJob } = await import('../functions/conversions/jobs.js');
    await job(`exam-${examId}`).set({ ...legacyJob(examId, exam, { provider: 'claude' }), status: 'ready' });
    await seedDrafts(`exam-${examId}`, count);
    return `exam-${examId}`;
  }

  test('jobs store the original title and its list suggestion (null when nothing matches)', async () => {
    const { legacyJob, submissionJob } = await import('../functions/conversions/jobs.js');
    const exam = (title) => ({ kind: 'JPG', files: [{ storagePath: 'imagess/a.jpg', order: 0 }], title });
    assert.deepEqual(
      [legacyJob('e', exam(' 2019 FİZİK LAB ')).placement.originalTitle, legacyJob('e', exam('2019 FİZİK LAB')).placement.suggestedTitle],
      ['2019 FİZİK LAB', '2019 LABORATUVAR'],
    );
    assert.equal(legacyJob('e', exam('DERS NOTU')).placement.suggestedTitle, null);
    const submission = {
      exam: '2017-2018 VİZE', kind: 'PDF', conversionProvider: 'claude',
      publishPlan: { examId: 'x', exam: { files: [{ storagePath: 'pdfs/a.pdf', order: 0 }] } },
    };
    const placement = submissionJob('s', submission).placement;
    assert.deepEqual([placement.originalTitle, placement.suggestedTitle], ['2017-2018 VİZE', '2018 VİZE']);
  });

  test('a legacy exam is renamed to the suggestion; its id never changes and the questions follow the title', async () => {
    await seedCatalog();
    const jobId = await seedReadyLegacy('T1', '2019 KISA SINAV 2 (FİZİK)');
    assert.equal((await getData(job(jobId))).placement.suggestedTitle, '2019 KISA SINAV 2');

    assert.deepEqual(await admin.publishExamConversionHandler(depsWith(), asAdmin({ jobId })), { examId: 'T1', questionCount: 1 });
    const exam = await getData(db.collection('exams').doc('T1'));
    assert.deepEqual([exam.title, exam.sortKey, exam.format], ['2019 KISA SINAV 2', '2019 KISA SINAV 2', 'structured']);
    const question = await getData(db.collection('questions').doc('T1-001'));
    assert.deepEqual([question.examId, question.examType, question.year], ['T1', 'kisa-sinav', 2019]);
    assert.equal((await getData(job(jobId))).publishedTitle, '2019 KISA SINAV 2');
  });

  test('the admin\'s title wins over the suggestion; the type and year come from it', async () => {
    await seedCatalog();
    const jobId = await seedReadyLegacy('T2', '2019 VİZE');

    await assert.rejects(
      admin.publishExamConversionHandler(depsWith(), asAdmin({ jobId, examTitle: '2019 VİZE SINAVI' })),
      { code: 'invalid-argument' },
    );
    await assert.rejects(admin.publishExamConversionHandler(depsWith(), asAdmin({ jobId, examTitle: 7 })), { code: 'invalid-argument' });
    await admin.publishExamConversionHandler(depsWith(), asAdmin({ jobId, examTitle: '  2020   YAZ OKULU FİNAL ' }));
    const exam = await getData(db.collection('exams').doc('T2'));
    assert.deepEqual([exam.title, exam.sortKey], ['2020 YAZ OKULU FİNAL', '2020 YAZ OKULU FİNAL']);
    const question = await getData(db.collection('questions').doc('T2-001'));
    assert.deepEqual([question.examType, question.year], ['final', 2020]);
  });

  test('an unrecognised title is refused until the admin picks a list name', async () => {
    await seedCatalog();
    const jobId = await seedReadyLegacy('T3', 'DERS NOTU');
    assert.equal((await getData(job(jobId))).placement.suggestedTitle, null);

    await assert.rejects(
      admin.publishExamConversionHandler(depsWith(), asAdmin({ jobId })),
      { code: 'failed-precondition', message: 'Sınav adı listeden seçilmeli.' },
    );
    assert.equal((await getData(job(jobId))).status, 'ready');
    assert.equal((await db.collection('questions').get()).size, 0);
    assert.equal((await getData(db.collection('exams').doc('T3'))).title, 'DERS NOTU');

    await admin.publishExamConversionHandler(depsWith(), asAdmin({ jobId, examTitle: 'ÇALIŞMA SORULARI' }));
    const exam = await getData(db.collection('exams').doc('T3'));
    assert.deepEqual([exam.title, exam.format], ['ÇALIŞMA SORULARI', 'structured']);
    const question = await getData(db.collection('questions').doc('T3-001'));
    assert.deepEqual([question.examType, question.year], ['calisma-sorulari', null]);
  });

  test('a submission\'s new exam gets the list title; the exam id and the submission text stay', async () => {
    await seedCatalog({ course: false });
    const { examId, jobId } = await seedReadySubmission('s-k28', { title: '2024 FİNAL' });
    await job(jobId).update({ placement: { originalTitle: '2024 FİNAL', suggestedTitle: '2024 FİNAL' } });

    await admin.publishExamConversionHandler(depsWith(), asAdmin({ jobId, examTitle: '2024 BÜTÜNLEME' }));
    const exam = await getData(db.collection('exams').doc(examId));
    assert.equal(examId, `${COURSE}__2024-final`);
    assert.deepEqual([exam.title, exam.sortKey], ['2024 BÜTÜNLEME', '2024 BÜTÜNLEME']);
    assert.equal((await getData(db.collection('submissions').doc('s-k28'))).exam, '2024 FİNAL');
    assert.equal((await getData(db.collection('questions').doc(`${examId}-001`))).examType, 'butunleme');
  });

  test('a duplicate renames the existing exam it replaces', async () => {
    await seedCatalog();
    await seedExam('T4', { title: '2024 FİNAL (ESKİ)' });
    const { jobId } = await seedReadyDuplicate('d-k28', 'T4');

    await admin.publishExamConversionHandler(depsWith(), asAdmin({ jobId }));
    const exam = await getData(db.collection('exams').doc('T4'));
    assert.deepEqual([exam.title, exam.sortKey], ['2024 FİNAL', '2024 FİNAL']);
  });
});

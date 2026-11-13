// The one-time legacy conversion script (`scripts/convert-legacy-exams.mjs`, K12c / K24) against the Firestore
// emulator: the required provider, the production guard, the dry run's counts and estimate, and an idempotent
// `--apply` (jobs with `budget: 'oneTime'`, a fake task queue). Nothing reaches a real project or Vertex AI.

import { test, before, after, beforeEach, describe } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { PROJECT_ID, assertLocalEmulators } from './helpers.mjs';

const requireFromFunctions = createRequire(new URL('../functions/package.json', import.meta.url));
const { initializeApp, deleteApp, getApp } = requireFromFunctions('firebase-admin/app');
const { getFirestore } = requireFromFunctions('firebase-admin/firestore');

const script = await import('../scripts/convert-legacy-exams.mjs');
const usage = await import('../functions/conversions/usage.js');

const DEPARTMENT = 'ege-universitesi__muhendislik-fakultesi__bilgisayar-muhendisligi';
const COURSE = `${DEPARTMENT}__algoritmalar`;

let db;

before(() => {
  assertLocalEmulators('FIRESTORE_EMULATOR_HOST');
  initializeApp({ projectId: PROJECT_ID });
  db = getFirestore('vifi');
});

after(async () => {
  await deleteApp(getApp());
});

beforeEach(async () => {
  const host = process.env.FIRESTORE_EMULATOR_HOST;
  const response = await fetch(`http://${host}/emulator/v1/projects/${PROJECT_ID}/databases/vifi/documents`, { method: 'DELETE' });
  assert.ok(response.ok);
});

function collectingLog() {
  const lines = [];
  return { lines, info: (message) => lines.push(message), error: (message) => lines.push(`ERR ${message}`) };
}

function fakeQueue() {
  const tasks = [];
  return { tasks, enqueueConversion: async (jobId, options = {}) => { tasks.push({ jobId, ...options }); } };
}

async function seedExam(id, { kind = 'JPG', files = 1, courseId = COURSE, extra = {} } = {}) {
  await db.collection('exams').doc(id).set({
    title: '2019 VİZE', universityId: 'ege-universitesi', facultyId: 'ege-universitesi__muhendislik-fakultesi',
    departmentId: DEPARTMENT, courseId, universityName: 'Ege Üniversitesi', facultyName: 'Mühendislik Fakültesi',
    departmentName: 'Bilgisayar Mühendisliği', courseName: 'Algoritmalar', kind, status: 'published',
    files: Array.from({ length: files }, (_, order) => ({ storagePath: `${kind === 'PDF' ? 'pdfs' : 'imagess'}/${id}-${order}.x`, order })),
    ...extra,
  });
}

/** e1 + e2 + e6 are convertible (2 + 4 + 1 estimated pages); everything else is skipped for a reason. */
async function seedArchive() {
  await seedExam('e1', { files: 2 });
  await seedExam('e2', { kind: 'PDF' });
  await seedExam('e3', { extra: { format: 'structured' } });
  await seedExam('e4');
  await db.collection('examConversions').doc('exam-e4').set({ source: { type: 'legacy', examId: 'e4' }, placement: { examId: 'e4' }, status: 'ready', model: { provider: 'claude' } });
  await seedExam('e5');
  await db.collection('examConversions').doc('exam-e5').set({ source: { type: 'legacy', examId: 'e5' }, placement: { examId: 'e5' }, status: 'failed', model: { provider: 'claude' } });
  await seedExam('e6');
  await db.collection('examConversions').doc('exam-e6').set({ source: { type: 'legacy', examId: 'e6' }, placement: { examId: 'e6' }, status: 'queued', model: null });
  await seedExam('e7', { extra: { status: 'draft' } });
  await seedExam('e8', { courseId: `${DEPARTMENT}__statik` });
  await seedExam('e9');
  // A duplicate submission of e9 is being converted: e9 must not get a second job.
  await db.collection('examConversions').doc('sub-dup').set({ source: { type: 'submission', submissionId: 'dup' }, placement: { examId: 'e9' }, status: 'processing' });
  await seedExam('e10', { files: 0 }); // no files: not convertible
}

const LOCAL = { FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080' };

describe('command line and the production guard', () => {
  test('the provider is required and the scope options are validated', async () => {
    const log = collectingLog();
    assert.equal(await script.run(['--course', COURSE], { db, env: LOCAL, log }), script.EXIT_REFUSED);
    assert.match(log.lines.join('\n'), /--provider claude\|gemini is required/);
    assert.equal(await script.run(['--provider', 'gpt'], { db, env: LOCAL, log }), script.EXIT_REFUSED);
    assert.equal(await script.run(['--provider', 'claude', '--course', 'a', '--department', 'b'], { db, env: LOCAL, log }), script.EXIT_REFUSED);
    assert.equal(await script.run(['--provider', 'claude', '--limit', '0'], { db, env: LOCAL, log }), script.EXIT_REFUSED);
    assert.equal(await script.run(['--provider', 'claude', '--apply', '--dry-run'], { db, env: LOCAL, log }), script.EXIT_REFUSED);
    assert.equal(await script.run(['--provider', 'claude', '--bogus'], { db, env: LOCAL, log }), script.EXIT_REFUSED);
  });

  test('a non-local target is refused without --project and a matching --confirm-project', async () => {
    const queue = fakeQueue();
    for (const [argv, env] of [
      [['--provider', 'claude', '--apply'], {}],
      [['--provider', 'claude', '--apply', '--project', 'vifi-831a8'], {}],
      [['--provider', 'claude', '--apply', '--project', 'vifi-831a8', '--confirm-project', 'other-proj'], {}],
      [['--provider', 'claude'], { FIRESTORE_EMULATOR_HOST: 'firestore.example.com:443' }],
    ]) {
      const log = collectingLog();
      // The injected emulator db proves the refusal happens before anything is read or written.
      assert.equal(await script.run(argv, { db, env, log, enqueueConversion: queue.enqueueConversion }), script.EXIT_REFUSED, argv.join(' '));
      assert.match(log.lines.join('\n'), /Refused/);
    }
    assert.equal(queue.tasks.length, 0);

    assert.deepEqual(script.resolveTarget({ project: 'vifi-831a8', confirmProject: 'vifi-831a8' }, {}), { local: false, projectId: 'vifi-831a8' });
    assert.deepEqual(script.resolveTarget({ project: null }, LOCAL), { local: true, projectId: 'demo-vifi' });
  });
});

describe('dry run', () => {
  test('counts the convertible exams of the scope, estimates pages and cost, writes nothing', async () => {
    await seedArchive();
    const plan = await script.planConversion(db, { provider: 'gemini', scope: { field: 'courseId', id: COURSE }, limit: null });
    assert.deepEqual(plan.candidates.map((exam) => exam.id), ['e1', 'e2', 'e6']);
    assert.equal(plan.scanned, 9);
    assert.deepEqual(plan.skipped, { notPublished: 1, structured: 1, notConvertible: 1, activeJob: 2, finishedJob: 1 });
    assert.equal(plan.pages, 7);
    const expected = [2, 4, 1].reduce((sum, pages) => sum + usage.estimateJobCostUsd({ provider: 'gemini', pageCount: pages }), 0);
    assert.equal(plan.estimatedCostUsd, Math.round(expected * 100) / 100);

    const log = collectingLog();
    const queue = fakeQueue();
    assert.equal(await script.run(['--provider', 'gemini', '--course', COURSE], { db, env: LOCAL, log, enqueueConversion: queue.enqueueConversion }), script.EXIT_OK);
    const output = log.lines.join('\n');
    assert.match(output, /dry run/);
    assert.match(output, /To convert: 3 exams, ~7 pages/);
    assert.match(output, new RegExp(`\\$${plan.estimatedCostUsd.toFixed(2).replace('.', '\\.')}`));
    assert.equal((await db.collection('examConversions').doc('exam-e1').get()).exists, false);
    assert.equal(queue.tasks.length, 0);

    // The whole archive (no scope) adds the other course's exam; --limit cuts in exam-id order.
    const all = await script.planConversion(db, { provider: 'gemini', scope: null, limit: null });
    assert.deepEqual(all.candidates.map((exam) => exam.id), ['e1', 'e2', 'e6', 'e8']);
    const limited = await script.planConversion(db, { provider: 'claude', scope: { field: 'departmentId', id: DEPARTMENT }, limit: 2 });
    assert.deepEqual([limited.candidates.map((exam) => exam.id), limited.notTaken], [['e1', 'e2'], 2]);
  });
});

describe('--apply', () => {
  test('creates one-time-budget jobs with the provider and enqueues them; a re-run starts nothing new', async () => {
    await seedArchive();
    const queue = fakeQueue();
    const log = collectingLog();
    const argv = ['--provider', 'claude', '--course', COURSE, '--apply'];
    assert.equal(await script.run(argv, { db, env: LOCAL, log, enqueueConversion: queue.enqueueConversion }), script.EXIT_OK);
    assert.deepEqual(queue.tasks.map(({ jobId }) => jobId).sort(), ['exam-e1', 'exam-e2', 'exam-e6']);
    for (const id of ['e1', 'e2', 'e6']) {
      const job = (await db.collection('examConversions').doc(`exam-${id}`).get()).data();
      assert.equal(job.status, 'queued', id);
      assert.equal(job.budget, 'oneTime', id);
      assert.deepEqual(job.model, { provider: 'claude', id: null }, id);
      assert.equal(job.requestedBy, script.REQUESTED_BY, id);
    }
    // Skipped exams are untouched.
    assert.equal((await db.collection('examConversions').doc('exam-e4').get()).get('status'), 'ready');
    assert.equal((await db.collection('examConversions').doc('exam-e5').get()).get('status'), 'failed');
    assert.equal((await db.collection('examConversions').doc('exam-e9').get()).exists, false);

    const again = collectingLog();
    assert.equal(await script.run(argv, { db, env: LOCAL, log: again, enqueueConversion: queue.enqueueConversion }), script.EXIT_OK);
    assert.match(again.lines.join('\n'), /Nothing to start/);
    assert.equal(queue.tasks.length, 3);
  });

  test('a failed enqueue is reported (exit 1) and the job is picked up by the next run', async () => {
    await seedExam('f1');
    const log = collectingLog();
    const failing = async () => { throw new Error('queue missing'); };
    assert.equal(await script.run(['--provider', 'gemini', '--apply'], { db, env: LOCAL, log, enqueueConversion: failing }), script.EXIT_FAILURES);
    assert.match((await db.collection('examConversions').doc('exam-f1').get()).get('error'), /^enqueue: queue missing/);

    const queue = fakeQueue();
    assert.equal(await script.run(['--provider', 'gemini', '--apply'], { db, env: LOCAL, log, enqueueConversion: queue.enqueueConversion }), script.EXIT_OK);
    assert.deepEqual(queue.tasks, [{ jobId: 'exam-f1' }]);
    assert.equal((await db.collection('examConversions').doc('exam-f1').get()).get('budget'), 'oneTime');
  });
});

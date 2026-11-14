// The one-time practice pool index build (`scripts/rebuild-pool-index.mjs`) against the Firestore emulator: the
// production guard, a dry run that writes nothing, `--apply` building the counts from every `__pN` part, deleting an
// index without pools and leaving a correct one untouched, and an idempotent re-run.

import { test, before, after, beforeEach, describe } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { PROJECT_ID, assertLocalEmulators } from './helpers.mjs';

const requireFromFunctions = createRequire(new URL('../functions/package.json', import.meta.url));
const { initializeApp, deleteApp, getApp } = requireFromFunctions('firebase-admin/app');
const { getFirestore } = requireFromFunctions('firebase-admin/firestore');

const script = await import('../scripts/rebuild-pool-index.mjs');

const NOW = new Date('2026-11-14T09:00:00Z');
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

const ids = (prefix, n) => Array.from({ length: n }, (_, k) => `${prefix}-${String(k + 1).padStart(3, '0')}`);

async function seed() {
  const pools = db.collection('questionPools');
  await pools.doc('mat__final__tr').set({ subjectId: 'mat', examType: 'final', scope: 'tr', part: 1, ids: ids('a', 4) });
  await pools.doc('mat__final__tr__p2').set({ subjectId: 'mat', examType: 'final', scope: 'tr', part: 2, ids: ids('b', 2) });
  await pools.doc('mat__final__u-ege').set({ subjectId: 'mat', examType: 'final', scope: 'university', universityId: 'ege', part: 1, ids: ids('a', 4) });
  await pools.doc('mat__vize__c-ege__muh__bil__mat').set({
    subjectId: 'mat', examType: 'vize', scope: 'course', courseId: 'ege__muh__bil__mat', part: 1, ids: ids('c', 1),
  });
  // A pool without its own fields (parsed from the id) and an emptied one (no index entry).
  await pools.doc('fiz__butunleme__tr').set({ ids: ids('f', 3) });
  await pools.doc('fiz__vize__tr').set({ subjectId: 'fiz', examType: 'vize', scope: 'tr', part: 1, ids: [] });
  await db.collection('subjects').doc('mat').set({ name: 'Matematik', aliases: [] });
  // A stale index for a subject without pools, and a correct one that must stay as is.
  await db.collection('questionPoolIndex').doc('eski').set({ subjectId: 'eski', name: 'Eski', types: { final: { tr: 1 } } });
}

describe('rebuild-pool-index', () => {
  test('production is refused without a repeated project; usage errors exit 2', async () => {
    const log = collectingLog();
    assert.equal(await script.run(['--apply'], { db, env: {}, log }), script.EXIT_REFUSED);
    assert.equal(await script.run(['--project', 'vifi-831a8'], { db, env: {}, log }), script.EXIT_REFUSED);
    assert.equal(await script.run(['--apply', '--dry-run'], { db, log }), script.EXIT_REFUSED);
    assert.equal(await script.run(['--bogus'], { db, log }), script.EXIT_REFUSED);
    assert.deepEqual(script.resolveTarget({ project: 'vifi-831a8', confirmProject: 'vifi-831a8' }, {}), { local: false, projectId: 'vifi-831a8' });
  });

  test('a dry run reports the plan and writes nothing', async () => {
    await seed();
    const log = collectingLog();
    assert.equal(await script.run([], { db, log }), script.EXIT_OK);
    assert.ok(log.lines.some((line) => line.includes('2 to create, 0 to update, 1 to delete')), log.lines.join('\n'));
    assert.equal((await db.collection('questionPoolIndex').doc('mat').get()).exists, false);
    assert.equal((await db.collection('questionPoolIndex').doc('eski').get()).exists, true);
  });

  test('--apply builds the index from every part; a re-run changes nothing', async () => {
    await seed();
    assert.equal(await script.run(['--apply'], { db, log: collectingLog(), now: NOW }), script.EXIT_OK);
    const mat = (await db.collection('questionPoolIndex').doc('mat').get()).data();
    assert.equal(mat.subjectId, 'mat');
    assert.equal(mat.name, 'Matematik');
    assert.deepEqual(mat.types, { final: { tr: 6, 'u-ege': 4 }, vize: { 'c-ege__muh__bil__mat': 1 } });
    assert.equal(mat.updatedAt.toMillis(), NOW.getTime());
    const fiz = (await db.collection('questionPoolIndex').doc('fiz').get()).data();
    assert.deepEqual([fiz.name, fiz.types], ['fiz', { butunleme: { tr: 3 } }]);
    assert.equal((await db.collection('questionPoolIndex').doc('eski').get()).exists, false);

    const log = collectingLog();
    assert.equal(await script.run(['--apply'], { db, log, now: new Date(NOW.getTime() + 1000) }), script.EXIT_OK);
    assert.ok(log.lines.some((line) => line.includes('0 to create, 0 to update, 0 to delete, 2 unchanged')), log.lines.join('\n'));
    assert.equal((await db.collection('questionPoolIndex').doc('mat').get()).get('updatedAt').toMillis(), NOW.getTime());
  });

  test('poolSpecOf parses an id when the fields are missing', () => {
    assert.deepEqual(script.poolSpecOf('mat__final__tr', {}), { subjectId: 'mat', examType: 'final', scope: 'tr' });
    assert.deepEqual(script.poolSpecOf('mat__final__u-ege__p2', {}), { subjectId: 'mat', examType: 'final', scope: 'university', universityId: 'ege' });
    assert.equal(script.poolSpecOf('garbage', {}), null);
  });
});

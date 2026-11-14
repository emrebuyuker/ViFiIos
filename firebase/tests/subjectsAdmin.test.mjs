// The admin subject-mapping callables (`functions/conversions/subjectsAdmin.js`, owner decision P5) against the
// Firestore emulator: the admin gate, listing subjects with their courses and question counts, changing a course's
// subject (existing or new; the K21 move of its questions and pools), renaming and merging — all idempotent.

import { test, before, after, beforeEach, describe, mock } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { assertLocalEmulators, PROJECT_ID } from './helpers.mjs';

const requireFromFunctions = createRequire(new URL('../functions/package.json', import.meta.url));
const { getFirestore } = requireFromFunctions('firebase-admin/firestore');
const { getApp, deleteApp } = requireFromFunctions('firebase-admin/app');

const DAY = new Date('2026-11-14T09:00:00Z');
const EGE = 'ege-universitesi';
const ITU = 'istanbul-teknik-universitesi';
const COURSE_EGE = `${EGE}__muhendislik-fakultesi__bilgisayar-muhendisligi__algoritmalar`;
const COURSE_ITU = `${ITU}__bilgisayar-fakultesi__yazilim__algoritma-analizi`;
const COURSE_OTHER = `${EGE}__muhendislik-fakultesi__bilgisayar-muhendisligi__veri-yapilari`;

let db;
let subjectsAdmin;
let schema;
let fns;

before(async () => {
  assertLocalEmulators('FIRESTORE_EMULATOR_HOST');
  mock.method(console, 'error', () => {});
  mock.method(console, 'warn', () => {});
  fns = await import('../functions/index.js');
  subjectsAdmin = await import('../functions/conversions/subjectsAdmin.js');
  schema = await import('../functions/conversions/schema.js');
  db = getFirestore('vifi');
});

after(async () => {
  await deleteApp(getApp());
});

beforeEach(async () => {
  const host = process.env.FIRESTORE_EMULATOR_HOST;
  const response = await fetch(`http://${host}/emulator/v1/projects/${PROJECT_ID}/databases/vifi/documents`, { method: 'DELETE' });
  assert.ok(response.ok);
  await seed();
});

const deps = () => ({ db, now: () => DAY });
const ADMIN = { uid: 'admin-1', token: { admin: true } };
const asAdmin = (data) => ({ auth: ADMIN, data });
const get = async (ref) => (await ref.get()).data();

async function seed() {
  const nodes = db.collection('catalogNodes');
  const node = (id, level, name, parentId, extra = {}) => nodes.doc(id).set({ level, name, parentId, status: 'published', childCount: 1, ...extra });
  await node(EGE, 'university', 'Ege Üniversitesi', '');
  await node(`${EGE}__muhendislik-fakultesi`, 'faculty', 'Mühendislik Fakültesi', EGE);
  await node(`${EGE}__muhendislik-fakultesi__bilgisayar-muhendisligi`, 'department', 'Bilgisayar Mühendisliği', `${EGE}__muhendislik-fakultesi`);
  await node(ITU, 'university', 'İstanbul Teknik Üniversitesi', '');
  await node(`${ITU}__bilgisayar-fakultesi`, 'faculty', 'Bilgisayar Fakültesi', ITU);
  await node(`${ITU}__bilgisayar-fakultesi__yazilim`, 'department', 'Yazılım', `${ITU}__bilgisayar-fakultesi`);
  const egeDepartment = `${EGE}__muhendislik-fakultesi__bilgisayar-muhendisligi`;
  await node(COURSE_EGE, 'course', 'Algoritmalar', egeDepartment, { subjectId: 'algoritmalar' });
  await node(COURSE_OTHER, 'course', 'Veri Yapıları', egeDepartment, { subjectId: 'veri-yapilari' });
  await node(COURSE_ITU, 'course', 'Algoritma Analizi', `${ITU}__bilgisayar-fakultesi__yazilim`, { subjectId: 'algoritma-analizi' });
  const subject = (id, name, aliases) => db.collection('subjects').doc(id).set({ name, aliases, createdAt: DAY, updatedAt: DAY });
  await subject('algoritmalar', 'Algoritmalar', ['algoritmalar']);
  await subject('veri-yapilari', 'Veri Yapıları', ['veri-yapilari']);
  await subject('algoritma-analizi', 'Algoritma Analizi', ['algoritma-analizi']);
  await question('e1-001', COURSE_EGE, EGE, 'algoritmalar');
  await question('e1-002', COURSE_EGE, EGE, 'algoritmalar');
  await question('i1-001', COURSE_ITU, ITU, 'algoritma-analizi');
  await question('v1-001', COURSE_OTHER, EGE, 'veri-yapilari');
  // The pools the publish would have written (country-wide, university and course scope) for the Ege questions.
  for (const spec of [{ scope: 'tr' }, { scope: 'university', universityId: EGE }, { scope: 'course', courseId: COURSE_EGE }]) {
    const full = { subjectId: 'algoritmalar', examType: 'final', ...spec };
    await db.collection('questionPools').doc(schema.questionPoolId({ ...full, part: 1 })).set({ ...full, part: 1, ids: ['e1-001', 'e1-002'], count: 2 });
  }
}

function question(id, courseId, universityId, subjectId) {
  return db.collection('questions').doc(id).set({ courseId, universityId, subjectId, examType: 'final', examId: id.split('-')[0] });
}

const poolIds = async (subjectId, spec) => (
  (await get(db.collection('questionPools').doc(schema.questionPoolId({ subjectId, examType: 'final', ...spec, part: 1 }))))?.ids
);

describe('admin gate', () => {
  test('every callable refuses a non-admin before touching a dependency', async () => {
    const calls = [
      subjectsAdmin.listSubjectsHandler, subjectsAdmin.setCourseSubjectHandler,
      subjectsAdmin.renameSubjectHandler, subjectsAdmin.mergeSubjectsHandler,
    ];
    for (const call of calls) {
      for (const auth of [null, { uid: 'u', token: {} }, { uid: 'u', token: { admin: 'true' } }]) {
        await assert.rejects(call({}, { auth, data: {} }), { code: 'permission-denied' });
      }
    }
  });

  test('the callables are wired and documented in the contract', () => {
    for (const name of ['listSubjects', 'setCourseSubject', 'renameSubject', 'mergeSubjects']) {
      assert.ok(schema.CALLABLES.includes(name), name);
      assert.equal(typeof fns[name], 'function', name);
    }
  });
});

describe('listSubjects', () => {
  test('returns every subject with its courses, names and question counts', async () => {
    const { subjects, truncated } = await subjectsAdmin.listSubjectsHandler(deps(), asAdmin({}));
    assert.equal(truncated, false);
    assert.deepEqual(subjects.map((subject) => subject.id), ['algoritma-analizi', 'algoritmalar', 'veri-yapilari']);
    const algorithms = subjects.find((subject) => subject.id === 'algoritmalar');
    assert.equal(algorithms.courseCount, 1);
    assert.equal(algorithms.questionCount, 2);
    assert.deepEqual(algorithms.courses, [{
      id: COURSE_EGE, name: 'Algoritmalar', universityId: EGE, universityName: 'Ege Üniversitesi',
      facultyName: 'Mühendislik Fakültesi', departmentName: 'Bilgisayar Mühendisliği', questionCount: 2,
    }]);
  });

  test('a subject without courses is listed with zero counts', async () => {
    await db.collection('subjects').doc('bos').set({ name: 'Boş', aliases: [] });
    const { subjects } = await subjectsAdmin.listSubjectsHandler(deps(), asAdmin({}));
    const empty = subjects.find((subject) => subject.id === 'bos');
    assert.deepEqual([empty.courseCount, empty.questionCount, empty.courses], [0, 0, []]);
  });
});

describe('setCourseSubject', () => {
  test('moves a course to an existing subject with its questions and pools, learning the course name', async () => {
    const result = await subjectsAdmin.setCourseSubjectHandler(deps(), asAdmin({ courseId: COURSE_ITU, subjectId: 'algoritmalar' }));
    assert.deepEqual(result, { subjectId: 'algoritmalar', subjectName: 'Algoritmalar', moved: 1 });
    assert.equal((await get(db.collection('catalogNodes').doc(COURSE_ITU))).subjectId, 'algoritmalar');
    assert.equal((await get(db.collection('questions').doc('i1-001'))).subjectId, 'algoritmalar');
    assert.deepEqual(await poolIds('algoritmalar', { scope: 'tr' }), ['e1-001', 'e1-002', 'i1-001']);
    assert.deepEqual(await poolIds('algoritmalar', { scope: 'university', universityId: ITU }), ['i1-001']);
    assert.ok((await get(db.collection('subjects').doc('algoritmalar'))).aliases.includes('algoritma-analizi'));
  });

  test('a new subject name creates (or reuses) the subject and moves the course', async () => {
    const result = await subjectsAdmin.setCourseSubjectHandler(deps(), asAdmin({ courseId: COURSE_EGE, newSubjectName: 'Algoritma ve Programlama' }));
    assert.deepEqual(result, { subjectId: 'algoritma-ve-programlama', subjectName: 'Algoritma ve Programlama', moved: 2 });
    const created = await get(db.collection('subjects').doc('algoritma-ve-programlama'));
    assert.equal(created.name, 'Algoritma ve Programlama');
    assert.ok(created.aliases.includes('algoritma-ve-programlama'));
    assert.deepEqual(await poolIds('algoritma-ve-programlama', { scope: 'course', courseId: COURSE_EGE }), ['e1-001', 'e1-002']);
    assert.equal(await poolIds('algoritmalar', { scope: 'tr' }), undefined, 'the old subject pool is emptied away');
    // Reusing an existing subject by name does not create a duplicate.
    const again = await subjectsAdmin.setCourseSubjectHandler(deps(), asAdmin({ courseId: COURSE_OTHER, newSubjectName: 'Algoritma ve Programlama' }));
    assert.equal(again.subjectId, 'algoritma-ve-programlama');
    assert.equal((await db.collection('subjects').get()).size, 4);
  });

  test('a repeated call is a no-op', async () => {
    const data = { courseId: COURSE_ITU, subjectId: 'algoritmalar' };
    await subjectsAdmin.setCourseSubjectHandler(deps(), asAdmin(data));
    const repeat = await subjectsAdmin.setCourseSubjectHandler(deps(), asAdmin(data));
    assert.equal(repeat.moved, 0);
    assert.deepEqual(await poolIds('algoritmalar', { scope: 'tr' }), ['e1-001', 'e1-002', 'i1-001']);
  });

  test('refuses bad input', async () => {
    const call = (data) => subjectsAdmin.setCourseSubjectHandler(deps(), asAdmin(data));
    await assert.rejects(call({ courseId: 'Bad Id', subjectId: 'algoritmalar' }), { code: 'invalid-argument' });
    await assert.rejects(call({ courseId: COURSE_ITU }), { code: 'invalid-argument' });
    await assert.rejects(call({ courseId: COURSE_ITU, subjectId: 'algoritmalar', newSubjectName: 'X' }), { code: 'invalid-argument' });
    await assert.rejects(call({ courseId: COURSE_ITU, newSubjectName: '   ' }), { code: 'invalid-argument' });
    await assert.rejects(call({ courseId: COURSE_ITU, subjectId: 'yok' }), { code: 'invalid-argument' });
    await assert.rejects(call({ courseId: 'ege-universitesi', subjectId: 'algoritmalar' }), { code: 'not-found' });
    await assert.rejects(call({ courseId: 'yok__yok__yok__yok', subjectId: 'algoritmalar' }), { code: 'not-found' });
  });
});

describe('renameSubject', () => {
  test('renames, keeps the id and learns both names as aliases', async () => {
    const result = await subjectsAdmin.renameSubjectHandler(deps(), asAdmin({ subjectId: 'algoritmalar', name: 'Algoritma ve Veri Yapıları' }));
    assert.deepEqual(result, { subjectId: 'algoritmalar', name: 'Algoritma ve Veri Yapıları' });
    const subject = await get(db.collection('subjects').doc('algoritmalar'));
    assert.equal(subject.name, 'Algoritma ve Veri Yapıları');
    assert.deepEqual([...subject.aliases].sort(), ['algoritma-ve-veri-yapilari', 'algoritmalar']);
    await subjectsAdmin.renameSubjectHandler(deps(), asAdmin({ subjectId: 'algoritmalar', name: 'Algoritma ve Veri Yapıları' }));
    assert.equal((await get(db.collection('subjects').doc('algoritmalar'))).aliases.length, 2);
  });

  test('updates the practice index name when that document exists; refuses bad input', async () => {
    await db.collection('questionPoolIndex').doc('algoritmalar').set({ subjectId: 'algoritmalar', name: 'Algoritmalar', types: {} });
    await subjectsAdmin.renameSubjectHandler(deps(), asAdmin({ subjectId: 'algoritmalar', name: 'Algoritmalar I' }));
    assert.equal((await get(db.collection('questionPoolIndex').doc('algoritmalar'))).name, 'Algoritmalar I');
    const call = (data) => subjectsAdmin.renameSubjectHandler(deps(), asAdmin(data));
    await assert.rejects(call({ subjectId: 'yok', name: 'Ad' }), { code: 'not-found' });
    await assert.rejects(call({ subjectId: 'algoritmalar', name: '  ' }), { code: 'invalid-argument' });
    await assert.rejects(call({ subjectId: 'algoritmalar', name: '***' }), { code: 'invalid-argument' });
    await assert.rejects(call({ subjectId: 'BAD ID', name: 'Ad' }), { code: 'invalid-argument' });
  });
});

describe('mergeSubjects', () => {
  const merge = (fromSubjectId, intoSubjectId) => subjectsAdmin.mergeSubjectsHandler(deps(), asAdmin({ fromSubjectId, intoSubjectId }));

  test('moves every course, learns the aliases and deletes the source; a repeat is a no-op', async () => {
    assert.deepEqual(await merge('algoritma-analizi', 'algoritmalar'), { moved: 1, merged: true });
    assert.equal((await db.collection('subjects').doc('algoritma-analizi').get()).exists, false);
    assert.equal((await get(db.collection('catalogNodes').doc(COURSE_ITU))).subjectId, 'algoritmalar');
    assert.equal((await get(db.collection('questions').doc('i1-001'))).subjectId, 'algoritmalar');
    assert.deepEqual(await poolIds('algoritmalar', { scope: 'tr' }), ['e1-001', 'e1-002', 'i1-001']);
    const into = await get(db.collection('subjects').doc('algoritmalar'));
    assert.deepEqual([...into.aliases].sort(), ['algoritma-analizi', 'algoritmalar']);
    assert.deepEqual(await merge('algoritma-analizi', 'algoritmalar'), { moved: 0, merged: false });
  });

  test('refuses itself, a missing target and bad ids', async () => {
    await assert.rejects(merge('algoritmalar', 'algoritmalar'), { code: 'invalid-argument' });
    await assert.rejects(merge('algoritmalar', 'yok'), { code: 'not-found' });
    await assert.rejects(merge('BAD ID', 'algoritmalar'), { code: 'invalid-argument' });
    assert.equal((await db.collection('subjects').doc('algoritmalar').get()).exists, true);
  });
});

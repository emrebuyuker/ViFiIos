// Admin subject-mapping callables (owner decision P5; contract: `CALLABLES` in conversions/schema.js): review and fix
// which country-wide course identity (`subjects/<id>` = `{ name, aliases[] }`) each course belongs to. Every handler
// requires the `admin: true` claim before touching a dependency. Changing a course's subject goes through the same
// K21 move as a publish (`moveCourseSubject` in publish.js: the course's published questions + pool entries move), so
// this file never touches questions or pools itself. All handlers are idempotent: a repeat finishes what a failed
// attempt left half done.

import { FieldValue, Timestamp } from 'firebase-admin/firestore';
import { HttpsError } from 'firebase-functions/v2/https';
import { ID_SEGMENT_PATTERN } from './schema.js';
import { moveCourseSubject } from './publish.js';
import { resolveSubject, subjectKey } from './subjects.js';
import { requireAdmin } from '../notifications/admin.js';

/** `listSubjects` reads at most this many subjects and this many course nodes; beyond it the answer is `truncated`. */
export const SUBJECT_LIST_LIMIT = 2000;
export const COURSE_LIST_LIMIT = 5000;
const SUBJECT_NAME_LIMIT = 120;
const COUNT_CONCURRENCY = 25;

const text = (value) => (typeof value === 'string' ? value.trim() : '');
const nowOf = (deps) => Timestamp.fromDate(deps.now?.() ?? new Date());

// MARK: - listSubjects

/** `listSubjects` → every subject with its courses (names of the university / faculty / department, question count). */
export async function listSubjectsHandler(deps, request) {
  requireAdmin(request);
  const { db } = deps;
  const [subjectSnapshot, courseSnapshot] = await Promise.all([
    db.collection('subjects').limit(SUBJECT_LIST_LIMIT).get(),
    // Only course nodes carry `subjectId`; a single-field inequality needs no composite index.
    db.collection('catalogNodes').where('subjectId', '!=', null).limit(COURSE_LIST_LIMIT).get(),
  ]);
  const courses = courseSnapshot.docs.filter((doc) => doc.get('level') === 'course');
  const names = await ancestorNames(db, courses);
  const counts = await questionCounts(db, courses.map((doc) => doc.id));

  const bySubject = new Map();
  for (const doc of courses) {
    const entry = describeCourse(doc, names, counts.get(doc.id) ?? 0);
    const list = bySubject.get(doc.get('subjectId')) ?? [];
    list.push(entry);
    bySubject.set(doc.get('subjectId'), list);
  }
  const subjects = subjectSnapshot.docs.map((doc) => {
    const list = (bySubject.get(doc.id) ?? []).sort((a, b) => a.name.localeCompare(b.name, 'tr'));
    return {
      id: doc.id,
      name: text(doc.get('name')) || doc.id,
      aliases: Array.isArray(doc.get('aliases')) ? doc.get('aliases') : [],
      courseCount: list.length,
      questionCount: list.reduce((sum, course) => sum + course.questionCount, 0),
      courses: list,
    };
  }).sort((a, b) => a.name.localeCompare(b.name, 'tr'));
  return {
    subjects,
    truncated: subjectSnapshot.size >= SUBJECT_LIST_LIMIT || courseSnapshot.size >= COURSE_LIST_LIMIT,
  };
}

function describeCourse(doc, names, questionCount) {
  const department = names.get(doc.get('parentId'));
  const faculty = names.get(department?.parentId);
  const university = names.get(faculty?.parentId);
  return {
    id: doc.id,
    name: text(doc.get('name')) || doc.id,
    universityId: university?.id ?? '',
    universityName: university?.name ?? '',
    facultyName: faculty?.name ?? '',
    departmentName: department?.name ?? '',
    questionCount,
  };
}

/** `Map<nodeId, { id, name, parentId }>` of the departments, faculties and universities above the courses. */
async function ancestorNames(db, courses) {
  const known = new Map();
  let ids = [...new Set(courses.map((doc) => doc.get('parentId')))];
  for (let level = 0; level < 3; level += 1) {
    const wanted = ids.filter((id) => ID_SEGMENT_PATTERN.test(id ?? '') && !known.has(id));
    if (wanted.length === 0) break;
    const snapshots = await getAllChunked(db, wanted.map((id) => db.collection('catalogNodes').doc(id)));
    for (const snapshot of snapshots.filter((item) => item.exists)) {
      known.set(snapshot.id, { id: snapshot.id, name: text(snapshot.get('name')) || snapshot.id, parentId: snapshot.get('parentId') });
    }
    ids = [...new Set(wanted.map((id) => known.get(id)?.parentId))];
  }
  return known;
}

async function getAllChunked(db, refs) {
  const result = [];
  for (let start = 0; start < refs.length; start += 300) result.push(...await db.getAll(...refs.slice(start, start + 300)));
  return result;
}

/** Published question count per course (server-side count aggregation, a few at a time). */
async function questionCounts(db, courseIds) {
  const counts = new Map();
  for (let start = 0; start < courseIds.length; start += COUNT_CONCURRENCY) {
    await Promise.all(courseIds.slice(start, start + COUNT_CONCURRENCY).map(async (id) => {
      const aggregate = await db.collection('questions').where('courseId', '==', id).count().get();
      counts.set(id, aggregate.data().count);
    }));
  }
  return counts;
}

// MARK: - setCourseSubject

/**
 * `setCourseSubject { courseId, subjectId | newSubjectName }` → `{ subjectId, subjectName, moved }`. Points the course
 * at an existing subject, or at the subject `newSubjectName` creates (or reuses by its slug), then moves the course's
 * published questions and pool entries (K21). The course's own name stays matchable as an alias of the new subject.
 */
export async function setCourseSubjectHandler(deps, request) {
  requireAdmin(request);
  const { db } = deps;
  const courseId = requireId(request.data?.courseId, 'Ders kimliği geçersiz.');
  const override = subjectChoice(request.data);
  const now = nowOf(deps);

  const courseRef = db.collection('catalogNodes').doc(courseId);
  const course = await courseRef.get();
  if (!course.exists || course.get('level') !== 'course') throw new HttpsError('not-found', 'Ders bulunamadı.');

  const subject = await resolveSubject((refOrQuery) => refOrQuery.get(), db, {
    courseNode: course, courseName: course.get('name'), override,
  });
  if (!subject) throw new HttpsError('invalid-argument', 'Ders adı geçersiz.');

  const batch = db.batch();
  const subjectRef = db.collection('subjects').doc(subject.id);
  if (subject.create) {
    batch.set(subjectRef, { ...subject.create, createdAt: now, updatedAt: now });
  } else if (subject.alias && !subject.aliases.includes(subject.alias)) {
    batch.update(subjectRef, { aliases: FieldValue.arrayUnion(subject.alias), updatedAt: now });
  }
  if (course.get('subjectId') !== subject.id) batch.update(courseRef, { subjectId: subject.id });
  await batch.commit();

  // Always runs: a repeat after a failed move resumes it, a finished one skips every question (no-op).
  const { moved } = await moveCourseSubject(deps, null, { courseId, toSubjectId: subject.id });
  return { subjectId: subject.id, subjectName: subject.name, moved };
}

// MARK: - renameSubject

/** `renameSubject { subjectId, name }` → `{ subjectId, name }`; the id never changes and the old name becomes an alias. */
export async function renameSubjectHandler(deps, request) {
  requireAdmin(request);
  const { db } = deps;
  const subjectId = requireId(request.data?.subjectId, 'Ders kimliği geçersiz.');
  const name = requireName(request.data?.name);
  const now = nowOf(deps);

  const ref = db.collection('subjects').doc(subjectId);
  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(ref);
    if (!snapshot.exists) throw new HttpsError('not-found', 'Ders bulunamadı.');
    const learnt = [subjectKey(snapshot.get('name')), subjectKey(name)].filter(Boolean);
    transaction.update(ref, { name, aliases: FieldValue.arrayUnion(...learnt), updatedAt: now });
  });
  // The practice index shows the name; keep it in step when the index document exists.
  const index = db.collection('questionPoolIndex').doc(subjectId);
  if ((await index.get()).exists) await index.update({ name });
  return { subjectId, name };
}

// MARK: - mergeSubjects

/**
 * `mergeSubjects { fromSubjectId, intoSubjectId }` → `{ moved, merged }` (`moved` = courses moved by this call).
 * `from`'s id, name and aliases are learnt by `into` first, then each of `from`'s courses moves (K21), and `from` is
 * deleted last — so a failed attempt is finished by repeating the call, and a repeat after success is a no-op.
 */
export async function mergeSubjectsHandler(deps, request) {
  requireAdmin(request);
  const { db } = deps;
  const fromId = requireId(request.data?.fromSubjectId, 'Ders kimliği geçersiz.');
  const intoId = requireId(request.data?.intoSubjectId, 'Ders kimliği geçersiz.');
  if (fromId === intoId) throw new HttpsError('invalid-argument', 'Bir ders kendisiyle birleştirilemez.');
  const now = nowOf(deps);

  const [from, into] = await db.getAll(db.collection('subjects').doc(fromId), db.collection('subjects').doc(intoId));
  if (!into.exists) throw new HttpsError('not-found', 'Hedef ders bulunamadı.');
  if (!from.exists) return { moved: 0, merged: false };

  const learnt = [...new Set([fromId, subjectKey(from.get('name')), ...(from.get('aliases') ?? [])].filter(Boolean))];
  await into.ref.update({ aliases: FieldValue.arrayUnion(...learnt), updatedAt: now });

  const courses = await db.collection('catalogNodes').where('subjectId', '==', fromId).get();
  let moved = 0;
  for (const course of courses.docs.filter((doc) => doc.get('level') === 'course')) {
    await course.ref.update({ subjectId: intoId });
    await moveCourseSubject(deps, null, { courseId: course.id, toSubjectId: intoId });
    moved += 1;
  }
  await from.ref.delete();
  return { moved, merged: true };
}

// MARK: - Input helpers

function requireId(value, message) {
  if (typeof value !== 'string' || !ID_SEGMENT_PATTERN.test(value)) throw new HttpsError('invalid-argument', message);
  return value;
}

function requireName(value) {
  const name = text(value);
  if (!name || [...name].length > SUBJECT_NAME_LIMIT || subjectKey(name) === null) {
    throw new HttpsError('invalid-argument', 'Ders adı geçersiz.');
  }
  return name;
}

/** Exactly one of `subjectId` / `newSubjectName`, in `resolveSubject`'s override shape. */
function subjectChoice(data) {
  const hasId = data?.subjectId !== undefined && data.subjectId !== null;
  const hasName = data?.newSubjectName !== undefined && data.newSubjectName !== null;
  if (hasId === hasName) throw new HttpsError('invalid-argument', 'Ya mevcut bir ders ya da yeni bir ders adı verilmeli.');
  return hasId
    ? { subjectId: requireId(data.subjectId, 'Ders kimliği geçersiz.') }
    : { newSubjectName: requireName(data.newSubjectName) };
}

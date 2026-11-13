// Country-wide course identities (`subjects/{subjectId}` = `{ name, aliases[] }`, TODO-4.2.0 Ek C): how a course is
// matched to a subject. Shared by `publishExamConversion` (publish.js, inside its transaction) and job creation
// (jobs.js / automatic.js, the suggestion shown on the review screen as `placement.subjectId` / `subjectName`), so
// the suggestion is exactly what an unchanged "Önerilen" publish resolves to.

import { HttpsError } from 'firebase-functions/v2/https';
import { ID_SEGMENT_PATTERN } from './schema.js';
import { slug } from './slug.js';

/** The normalised alias of a course name (its slug); `null` when the name has no letters or digits. */
export function subjectKey(name) {
  const key = slug(String(name ?? ''));
  return key === 'unknown' ? null : key;
}

const text = (value) => (typeof value === 'string' ? value.trim() : '');

/**
 * The exam's subject: the admin's choice (`subjectId` must exist; `newSubjectName` creates or reuses
 * `subjects/<slug>`), else the course node's `subjectId`, else a subject whose id or `aliases` match the course
 * name's slug, else a new subject named after the course. `null` only when the course has no usable name.
 *
 * `read(refOrQuery)` is `transaction.get` inside a transaction, or a plain `.get()` outside one.
 *
 * @returns {Promise<{ id: string, name: string, create: object|null, aliases: string[], alias: string|null }|null>}
 */
export async function resolveSubject(read, db, { courseNode, courseName, override }) {
  const alias = subjectKey(courseName);
  const subjects = db.collection('subjects');
  const existing = (snapshot) => ({
    id: snapshot.id,
    name: text(snapshot.get('name')) || text(courseName),
    create: null,
    aliases: snapshot.get('aliases') ?? [],
    alias,
  });

  if (override?.subjectId) {
    const snapshot = await read(subjects.doc(override.subjectId));
    if (!snapshot.exists) throw new HttpsError('invalid-argument', 'Seçilen ders kimliği bulunamadı.');
    return existing(snapshot);
  }
  if (override?.newSubjectName) {
    const id = subjectKey(override.newSubjectName);
    const snapshot = await read(subjects.doc(id));
    return snapshot.exists
      ? existing(snapshot)
      : {
        id,
        name: override.newSubjectName,
        create: { name: override.newSubjectName, aliases: [...new Set([id, alias].filter(Boolean))] },
        aliases: [],
        alias,
      };
  }

  const nodeSubjectId = courseNode?.exists ? courseNode.get('subjectId') : null;
  if (typeof nodeSubjectId === 'string' && ID_SEGMENT_PATTERN.test(nodeSubjectId)) {
    const snapshot = await read(subjects.doc(nodeSubjectId));
    if (snapshot.exists) return existing(snapshot);
  }
  if (!alias) return null;
  const byId = await read(subjects.doc(alias));
  if (byId.exists) return existing(byId);
  const byAlias = await read(subjects.where('aliases', 'array-contains', alias).limit(1));
  if (!byAlias.empty) return existing(byAlias.docs[0]);
  return { id: alias, name: text(courseName), create: { name: text(courseName), aliases: [alias] }, aliases: [], alias };
}

/**
 * The subject a job suggests before review (`placement.subjectId` / `placement.subjectName`): what an automatic
 * publish would resolve to right now — an existing subject, or the one it would create from the course name. Read
 * outside any transaction; best effort (a failed read only leaves the suggestion out).
 *
 * @returns {Promise<{ subjectId: string, subjectName: string }|null>}
 */
export async function suggestSubject(db, { courseId, courseName }) {
  const read = (refOrQuery) => refOrQuery.get();
  const courseNode = ID_SEGMENT_PATTERN.test(courseId ?? '') ? await read(db.collection('catalogNodes').doc(courseId)) : null;
  const name = text(courseName) || text(courseNode?.exists ? courseNode.get('name') : '');
  const subject = await resolveSubject(read, db, { courseNode, courseName: name, override: null });
  return subject ? { subjectId: subject.id, subjectName: subject.name } : null;
}

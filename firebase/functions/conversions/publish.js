// Publishing a reviewed conversion (the second approval, K1) and the published questions' later life (K14, K15,
// exam deletion). Contract: conversions/schema.js; data model: TODO-4.2.0 Ek A / Ek C.
//
// `publishExamConversion` runs in ONE transaction:
// - a submission job executes the submission's `publishPlan` (written by the 4.2.0 admin client at the first
//   approval): missing catalog nodes are created, existing parents get `childCount + 1`, and the exam document is
//   created. Node existence is re-read here, so a plan made stale by another publish in the meantime still keeps
//   `childCount` right; a legacy job uses the exam that already exists;
// - the drafts become `questions/<examId>-<nnn>` (published shape + denormalised query keys + `schemaVersion`);
//   questions of an earlier publish of the same exam that are no longer there are deleted;
// - `exams/<id>` gets `format: 'structured'`, `questionCount`, `structuredAt`, `conversionJobId` (its `files` are kept,
//   so 4.1.0 and Android still show the original pages);
// - the practice pools (`questionPools`, scopes tr / u- / c-, split into `__pN` parts) gain the new ids and lose the
//   removed ones; the subject (`subjects/<id>` + `catalogNodes/<courseId>.subjectId`) is resolved or created;
// - the job becomes `published` and the submission gets `publishedExamId`.
// Then, for a submission, the department's "new exam" notice goes out (moved here from the first approval).
//
// Handlers take their dependencies (`db`, `now`, plus what `deliverNotification` needs; `bucket` for the cleanup)
// as the first argument, like the notification handlers.

import { FieldValue, Timestamp } from 'firebase-admin/firestore';
import { HttpsError } from 'firebase-functions/v2/https';
import * as logger from 'firebase-functions/logger';
import {
  EXAM_TYPES,
  ID_SEGMENT_PATTERN,
  JOB_ID_PATTERN,
  LIMITS,
  QUESTION_SCHEMA_VERSION,
  parseExamTitle,
  plainSpeech,
  publishedQuestionId,
  questionOrderKey,
  questionPoolId,
} from './schema.js';
import { slug } from './slug.js';
import { DRAFTS, JOBS, isPlainObject, text } from './jobs.js';
import { notifyNewExam } from '../notifications/automatic.js';
import { requireAdmin } from '../notifications/admin.js';

/** Ids per pool document before the next `__pN` part starts (~1 MiB / ~60 bytes per id, with headroom). */
export const POOL_PART_LIMIT = 15000;
/** Safety stop when walking a pool's parts. */
const MAX_POOL_PARTS = 50;
const SUBJECT_NAME_LIMIT = 120;
const CATALOG_LEVELS = Object.freeze(['university', 'faculty', 'department', 'course']);

// MARK: - publishExamConversion

/**
 * `publishExamConversion` `{ jobId, subjectId?, newSubjectName? }` → `{ examId, questionCount }`. Idempotent: a job
 * that is already `published` returns its result and writes nothing.
 */
export async function publishExamConversionHandler(deps, request) {
  const uid = requireAdmin(request);
  const jobId = requireJobId(request.data?.jobId);
  const override = subjectOverride(request.data);
  const { db } = deps;
  const now = Timestamp.fromDate(deps.now?.() ?? new Date());
  const jobRef = db.collection(JOBS).doc(jobId);

  const result = await db.runTransaction(async (transaction) => {
    // --- Reads (all before any write) ---
    const jobSnapshot = await transaction.get(jobRef);
    if (!jobSnapshot.exists) throw new HttpsError('not-found', 'Dönüştürme işi bulunamadı.');
    const job = jobSnapshot.data();
    if (job.status === 'published') {
      return { examId: job.publishedExamId, questionCount: job.questionCount ?? 0, alreadyPublished: true };
    }
    if (job.status !== 'ready') throw new HttpsError('failed-precondition', 'Yalnızca hazır bir taslak yayınlanabilir.');

    const draftSnapshot = await transaction.get(jobRef.collection(DRAFTS).orderBy('order'));
    const drafts = draftSnapshot.docs.map((doc) => validDraft(doc.data(), doc.id));
    if (drafts.length === 0) throw new HttpsError('failed-precondition', 'Taslakta soru yok.');

    const target = job.source?.type === 'submission'
      ? await readSubmissionTarget(transaction, db, job)
      : await readLegacyTarget(transaction, db, job);
    const subject = await resolveSubject(transaction, db, {
      courseNode: target.courseNode,
      courseName: target.names.course,
      override,
    });
    const existingQuestions = (await transaction.get(db.collection('questions').where('examId', '==', target.examId))).docs;

    const { examType, year } = parseExamTitle(target.names.exam);
    const keys = {
      subjectId: subject?.id ?? null,
      courseId: target.ids.course,
      universityId: target.ids.university,
      facultyId: target.ids.faculty,
      departmentId: target.ids.department,
      examType,
      year,
    };
    const questions = drafts.map((draft) => ({
      id: publishedQuestionId(target.examId, draft.order),
      data: publishedQuestion(draft, { examId: target.examId, keys, now }),
    }));
    const keptIds = new Set(questions.map(({ id }) => id));
    const pools = await readPools(transaction, db, [
      ...existingQuestions.map((doc) => ({ id: doc.id, keys: doc.data(), remove: true })),
      ...questions.map(({ id, data }) => ({ id, keys: data, remove: false })),
    ]);

    // --- Writes ---
    if (target.type === 'submission') {
      writeCatalogAndExam(transaction, db, target, { now, questionCount: questions.length, jobId, subjectId: subject?.id });
    } else {
      transaction.update(db.collection('exams').doc(target.examId), {
        format: 'structured', questionCount: questions.length, structuredAt: now, conversionJobId: jobId,
      });
    }
    if (subject) writeSubject(transaction, db, subject, target, now);
    for (const doc of existingQuestions) if (!keptIds.has(doc.id)) transaction.delete(doc.ref);
    for (const { id, data } of questions) transaction.set(db.collection('questions').doc(id), data);
    writePools(transaction, db, pools, now);
    transaction.update(jobRef, {
      status: 'published',
      publishedAt: now,
      reviewedBy: uid,
      publishedExamId: target.examId,
      questionCount: questions.length,
      subjectId: subject?.id ?? null,
      error: null,
    });
    if (target.type === 'submission') {
      transaction.update(target.submissionRef, { publishedExamId: target.examId });
    }
    return {
      examId: target.examId,
      questionCount: questions.length,
      notify: target.type === 'submission'
        ? { submissionId: target.submissionRef.id, examId: target.examId, ownerId: target.ownerId }
        : null,
    };
  });

  if (result.notify) {
    try {
      await notifyNewExam(deps, result.notify);
    } catch (error) {
      // The exam is live either way; a lost department notice must not fail the approval.
      logger.error('The department "new exam" notice failed', { jobId, error: error?.message ?? String(error) });
    }
  }
  return { examId: result.examId, questionCount: result.questionCount };
}

/** A submission job's target: the plan's ids, the catalog nodes' current existence and the exam (must not exist). */
async function readSubmissionTarget(transaction, db, job) {
  const submissionId = job.source?.submissionId;
  if (!ID_SEGMENT_PATTERN.test(submissionId ?? '')) throw new HttpsError('failed-precondition', 'İşin gönderimi geçersiz.');
  const submissionRef = db.collection('submissions').doc(submissionId);
  const submissionSnapshot = await transaction.get(submissionRef);
  const submission = submissionSnapshot.exists ? submissionSnapshot.data() : null;
  const plan = submission?.publishPlan;
  const ids = {
    university: plan?.universityId,
    faculty: plan?.facultyId,
    department: plan?.departmentId,
    course: plan?.courseId,
  };
  if (!isPlainObject(plan) || !isPlainObject(plan.exam) || !ID_SEGMENT_PATTERN.test(plan.examId ?? '')
    || !Object.values(ids).every((id) => ID_SEGMENT_PATTERN.test(id ?? ''))) {
    throw new HttpsError('failed-precondition', 'Gönderimin yayın planı eksik.');
  }
  if (submission.status !== 'approved') throw new HttpsError('failed-precondition', 'Gönderim onaylı değil.');

  const examRef = db.collection('exams').doc(plan.examId);
  const nodeRefs = CATALOG_LEVELS.map((level) => db.collection('catalogNodes').doc(ids[level]));
  const [examSnapshot, ...nodeSnapshots] = await transaction.getAll(examRef, ...nodeRefs);
  if (examSnapshot.exists) {
    throw new HttpsError('already-exists', 'Bu sınav arşivde zaten var. Taslağı iptal edebilirsin.');
  }
  const names = {
    university: text(plan.exam.universityName) || text(submission.university),
    faculty: text(plan.exam.facultyName) || text(submission.faculty),
    department: text(plan.exam.departmentName) || text(submission.department),
    course: text(plan.exam.courseName) || text(submission.lesson),
    exam: text(plan.exam.title) || text(submission.exam),
  };
  return {
    type: 'submission',
    examId: plan.examId,
    examRef,
    plan,
    ids,
    names,
    nodes: nodeSnapshots,
    courseNode: nodeSnapshots[3],
    submissionRef,
    ownerId: text(submission.ownerId),
  };
}

/** A legacy job's target: the published exam itself. */
async function readLegacyTarget(transaction, db, job) {
  const examId = job.source?.examId;
  if (!ID_SEGMENT_PATTERN.test(examId ?? '')) throw new HttpsError('failed-precondition', 'İşin sınavı geçersiz.');
  const examSnapshot = await transaction.get(db.collection('exams').doc(examId));
  const exam = examSnapshot.exists ? examSnapshot.data() : null;
  if (!exam || exam.status !== 'published') throw new HttpsError('failed-precondition', 'Sınav arşivde bulunamadı.');
  const ids = {
    university: text(exam.universityId),
    faculty: text(exam.facultyId),
    department: text(exam.departmentId),
    course: text(exam.courseId),
  };
  const courseNode = ID_SEGMENT_PATTERN.test(ids.course)
    ? await transaction.get(db.collection('catalogNodes').doc(ids.course))
    : null;
  return {
    type: 'legacy',
    examId,
    ids,
    names: {
      course: text(exam.courseName) || text(courseNode?.exists ? courseNode.get('name') : ''),
      exam: text(exam.title),
    },
    courseNode,
  };
}

/**
 * Creates the missing catalog nodes, bumps `childCount` of the existing parent whose child is new (as iOS
 * `ArchivePublishPlan`, but on the nodes' state now) and creates the exam document from the plan.
 */
function writeCatalogAndExam(transaction, db, target, { now, questionCount, jobId, subjectId }) {
  const planned = new Map((Array.isArray(target.plan.nodesToCreate) ? target.plan.nodesToCreate : [])
    .filter((node) => isPlainObject(node) && typeof node.id === 'string')
    .map(({ id, ...fields }) => [id, fields]));
  const parents = { university: '', faculty: target.ids.university, department: target.ids.faculty, course: target.ids.department };

  let childIsNew = true; // the exam itself
  for (let index = CATALOG_LEVELS.length - 1; index >= 0; index -= 1) {
    const level = CATALOG_LEVELS[index];
    const id = target.ids[level];
    const ref = db.collection('catalogNodes').doc(id);
    if (!target.nodes[index].exists) {
      transaction.create(ref, {
        ...(planned.get(id) ?? {}),
        level,
        name: planned.get(id)?.name ?? target.names[level],
        parentId: parents[level],
        status: 'published',
        childCount: 1,
        slug: slug(planned.get(id)?.name ?? target.names[level]),
        source: 'submission',
        ...(level === 'course' && subjectId ? { subjectId } : {}),
      });
      childIsNew = true;
    } else {
      // One write per node: the count and (for the course) the subject together.
      const update = {
        ...(childIsNew ? { childCount: FieldValue.increment(1) } : {}),
        ...(level === 'course' && subjectId && target.nodes[index].get('subjectId') !== subjectId ? { subjectId } : {}),
      };
      if (Object.keys(update).length > 0) transaction.update(ref, update);
      childIsNew = false;
    }
  }

  transaction.create(target.examRef, {
    ...target.plan.exam,
    title: target.names.exam,
    universityId: target.ids.university,
    facultyId: target.ids.faculty,
    departmentId: target.ids.department,
    courseId: target.ids.course,
    status: 'published',
    format: 'structured',
    questionCount,
    structuredAt: now,
    conversionJobId: jobId,
  });
}

// MARK: - Published question shape

/** A draft question checked for what publishing needs; `failed-precondition` names the bad one. */
function validDraft(draft, docId) {
  const where = `Soru ${draft?.label ?? docId}`;
  if (!Number.isInteger(draft?.order) || draft.order < 1 || draft.order > 999) {
    throw new HttpsError('failed-precondition', `${where}: sıra numarası geçersiz.`);
  }
  if (!text(draft.text)) throw new HttpsError('failed-precondition', `${where}: metin boş.`);
  if (!text(draft.answer?.text)) throw new HttpsError('failed-precondition', `${where}: cevap boş.`);
  return draft;
}

/**
 * The published question (Ek A): content + query keys + `schemaVersion` + `updatedAt`. Review-only draft fields
 * (`confidence`, `needsReview`, `figureBoxes`, `editedBy`, …) are left out.
 */
export function publishedQuestion(draft, { examId, keys, now }) {
  const figures = (Array.isArray(draft.figures) ? draft.figures : [])
    .filter((figure) => typeof figure?.storagePath === 'string' && figure.storagePath.startsWith('questionFigures/'))
    .map(({ storagePath, width, height }) => ({
      storagePath,
      width: Number.isInteger(width) ? width : null,
      height: Number.isInteger(height) ? height : null,
    }));
  const textValue = text(draft.text);
  return {
    schemaVersion: QUESTION_SCHEMA_VERSION,
    examId,
    order: draft.order,
    label: text(draft.label) || String(draft.order),
    text: textValue,
    speech: text(draft.speech) || plainSpeech(textValue),
    choices: (Array.isArray(draft.choices) ? draft.choices : [])
      .filter((choice) => text(choice?.label) && text(choice?.text))
      .map((choice) => ({ label: text(choice.label), text: text(choice.text) })),
    figures,
    answer: answerOf(draft.answer),
    solution: (Array.isArray(draft.solution) ? draft.solution : []).map(text).filter(Boolean),
    topics: (Array.isArray(draft.topics) ? draft.topics : []).filter((topic) => typeof topic === 'string' && topic),
    difficulty: Number.isInteger(draft.difficulty) ? Math.min(3, Math.max(1, draft.difficulty)) : 2,
    hasFigure: figures.length > 0,
    subjectId: keys.subjectId ?? null,
    courseId: keys.courseId ?? null,
    universityId: keys.universityId ?? null,
    facultyId: keys.facultyId ?? null,
    departmentId: keys.departmentId ?? null,
    examType: keys.examType ?? null,
    year: keys.year ?? null,
    updatedAt: now,
  };
}

function answerOf(answer) {
  return {
    text: text(answer?.text),
    ...(text(answer?.choice) ? { choice: text(answer.choice) } : {}),
    ...(text(answer?.speech) ? { speech: text(answer.speech) } : {}),
  };
}

// MARK: - Subjects (country-wide course identities, Ek C)

/** `{ subjectId }` (an existing subject) or `{ newSubjectName }` from the request; `null` for automatic matching. */
function subjectOverride(data) {
  const subjectId = data?.subjectId;
  const newSubjectName = data?.newSubjectName;
  if (subjectId !== undefined && subjectId !== null && newSubjectName !== undefined && newSubjectName !== null) {
    throw new HttpsError('invalid-argument', 'Ya mevcut bir ders kimliği ya da yeni bir ders adı verilmeli, ikisi birden değil.');
  }
  if (subjectId !== undefined && subjectId !== null) {
    if (typeof subjectId !== 'string' || !ID_SEGMENT_PATTERN.test(subjectId)) {
      throw new HttpsError('invalid-argument', 'Ders kimliği geçersiz.');
    }
    return { subjectId };
  }
  if (newSubjectName !== undefined && newSubjectName !== null) {
    const name = text(newSubjectName);
    if (!name || [...name].length > SUBJECT_NAME_LIMIT || slug(name) === 'unknown') {
      throw new HttpsError('invalid-argument', 'Yeni ders adı geçersiz.');
    }
    return { newSubjectName: name };
  }
  return null;
}

/** The normalised alias of a course name (its slug); `null` when the name has no letters or digits. */
export function subjectKey(name) {
  const key = slug(String(name ?? ''));
  return key === 'unknown' ? null : key;
}

/**
 * The exam's subject: the admin's choice (`subjectId` must exist; `newSubjectName` creates or reuses
 * `subjects/<slug>`), else the course node's `subjectId`, else a subject whose id or `aliases` match the course
 * name's slug, else a new subject named after the course. `null` only when the course has no usable name.
 *
 * @returns {Promise<{ id: string, create: object|null, aliases: string[], alias: string|null }|null>}
 */
async function resolveSubject(transaction, db, { courseNode, courseName, override }) {
  const alias = subjectKey(courseName);
  const subjects = db.collection('subjects');
  const existing = (snapshot) => ({ id: snapshot.id, create: null, aliases: snapshot.get('aliases') ?? [], alias });

  if (override?.subjectId) {
    const snapshot = await transaction.get(subjects.doc(override.subjectId));
    if (!snapshot.exists) throw new HttpsError('invalid-argument', 'Seçilen ders kimliği bulunamadı.');
    return existing(snapshot);
  }
  if (override?.newSubjectName) {
    const id = subjectKey(override.newSubjectName);
    const snapshot = await transaction.get(subjects.doc(id));
    return snapshot.exists
      ? existing(snapshot)
      : { id, create: { name: override.newSubjectName, aliases: [...new Set([id, alias].filter(Boolean))] }, aliases: [], alias };
  }

  const nodeSubjectId = courseNode?.exists ? courseNode.get('subjectId') : null;
  if (typeof nodeSubjectId === 'string' && ID_SEGMENT_PATTERN.test(nodeSubjectId)) {
    const snapshot = await transaction.get(subjects.doc(nodeSubjectId));
    if (snapshot.exists) return existing(snapshot);
  }
  if (!alias) return null;
  const byId = await transaction.get(subjects.doc(alias));
  if (byId.exists) return existing(byId);
  const byAlias = await transaction.get(subjects.where('aliases', 'array-contains', alias).limit(1));
  if (!byAlias.empty) return existing(byAlias.docs[0]);
  return { id: alias, create: { name: text(courseName), aliases: [alias] }, aliases: [], alias };
}

/** Writes the subject (new, or a learnt alias) and points the course node at it. */
function writeSubject(transaction, db, subject, target, now) {
  const ref = db.collection('subjects').doc(subject.id);
  if (subject.create) {
    transaction.create(ref, { ...subject.create, createdAt: now, updatedAt: now });
  } else if (subject.alias && !subject.aliases.includes(subject.alias)) {
    transaction.update(ref, { aliases: FieldValue.arrayUnion(subject.alias), updatedAt: now });
  }
  // A submission's course node is written once by `writeCatalogAndExam` (created with, or updated to, the subject).
  if (target.type === 'legacy' && target.courseNode?.exists && target.courseNode.get('subjectId') !== subject.id) {
    transaction.update(target.courseNode.ref, { subjectId: subject.id });
  }
}

// MARK: - Question pools (Ek C)

/** The pool part-1 ids a published question belongs to (none without a subject or a known exam type). */
export function poolBases(keys) {
  if (!ID_SEGMENT_PATTERN.test(keys?.subjectId ?? '') || !EXAM_TYPES.includes(keys?.examType)) return [];
  const common = { subjectId: keys.subjectId, examType: keys.examType };
  const specs = [{ ...common, scope: 'tr' }];
  if (ID_SEGMENT_PATTERN.test(keys.universityId ?? '')) specs.push({ ...common, scope: 'university', universityId: keys.universityId });
  if (ID_SEGMENT_PATTERN.test(keys.courseId ?? '')) specs.push({ ...common, scope: 'course', courseId: keys.courseId });
  return specs.map((spec) => ({ spec, base: questionPoolId(spec) }));
}

/**
 * Reads every part of the pools touched by `changes` (`[{ id, keys, remove }]`: a question id leaving the pools of
 * `keys`, or joining them) — all reads, so the caller can write afterwards in the same transaction.
 */
export async function readPools(transaction, db, changes) {
  const pools = new Map();
  for (const change of changes) {
    for (const { spec, base } of poolBases(change.keys)) {
      if (!pools.has(base)) pools.set(base, { spec, parts: [], add: new Set(), remove: new Set() });
      pools.get(base)[change.remove ? 'remove' : 'add'].add(change.id);
    }
  }
  for (const pool of pools.values()) {
    for (let part = 1; part <= MAX_POOL_PARTS; part += 1) {
      const ref = db.collection('questionPools').doc(questionPoolId({ ...pool.spec, part }));
      const snapshot = await transaction.get(ref);
      if (!snapshot.exists) {
        pool.parts.push({ ref, part, ids: null });
        break;
      }
      pool.parts.push({ ref, part, ids: Array.isArray(snapshot.get('ids')) ? snapshot.get('ids') : [] });
    }
  }
  return pools;
}

/**
 * Applies the pools' changes: removed ids leave every part (an id both removed and added stays), new ids fill the
 * parts in order and open the next `__pN` part when one is full. Only changed parts are written; an emptied last
 * part is deleted.
 */
export function writePools(transaction, db, pools, now) {
  for (const pool of pools.values()) {
    const existingParts = pool.parts.filter((part) => part.ids !== null);
    const present = new Set(existingParts.flatMap((part) => part.ids));
    const next = existingParts.map((part) => ({
      ...part,
      original: part.ids,
      ids: part.ids.filter((id) => !pool.remove.has(id) || pool.add.has(id)),
    }));
    let pending = [...pool.add].filter((id) => !present.has(id));
    for (const part of next) {
      const room = POOL_PART_LIMIT - part.ids.length;
      if (room > 0 && pending.length > 0) {
        part.ids = [...part.ids, ...pending.slice(0, room)];
        pending = pending.slice(room);
      }
    }
    while (pending.length > 0) {
      const partNumber = next.length + 1;
      next.push({
        ref: db.collection('questionPools').doc(questionPoolId({ ...pool.spec, part: partNumber })),
        part: partNumber,
        original: null,
        ids: pending.slice(0, POOL_PART_LIMIT),
      });
      pending = pending.slice(POOL_PART_LIMIT);
    }
    next.forEach((part, index) => {
      const changed = part.original === null || part.original.length !== part.ids.length
        || part.original.some((id, k) => part.ids[k] !== id);
      if (!changed) return;
      if (part.ids.length === 0 && index === next.length - 1 && part.original !== null) {
        transaction.delete(part.ref);
        return;
      }
      transaction.set(part.ref, {
        subjectId: pool.spec.subjectId,
        examType: pool.spec.examType,
        scope: pool.spec.scope,
        ...(pool.spec.universityId ? { universityId: pool.spec.universityId } : {}),
        ...(pool.spec.courseId ? { courseId: pool.spec.courseId } : {}),
        part: part.part,
        ids: part.ids,
        count: part.ids.length,
        updatedAt: now,
      });
    });
  }
}

// MARK: - discardExamConversion (K14 "Sınavı iptal et")

/**
 * `discardExamConversion` `{ jobId }` → `{ status: 'discarded' }`. A queued, ready or failed job ends for good; the
 * exam stays as it is (a legacy exam keeps its pages; a submission's exam is never published). Coins are never
 * taken back. A running job must finish first; a published one cannot be discarded. Drafts are kept for reference.
 */
export async function discardExamConversionHandler(deps, request) {
  const uid = requireAdmin(request);
  const jobId = requireJobId(request.data?.jobId);
  const ref = deps.db.collection(JOBS).doc(jobId);
  const now = Timestamp.fromDate(deps.now?.() ?? new Date());
  return deps.db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(ref);
    if (!snapshot.exists) throw new HttpsError('not-found', 'Dönüştürme işi bulunamadı.');
    const status = snapshot.get('status');
    if (status === 'discarded') return { status };
    if (status === 'published') throw new HttpsError('failed-precondition', 'Yayınlanmış bir sınav iptal edilemez.');
    if (status === 'processing') throw new HttpsError('failed-precondition', 'Dönüştürme sürüyor; bitince iptal edebilirsin.');
    transaction.update(ref, { status: 'discarded', reviewedBy: uid, discardedAt: now });
    return { status: 'discarded' };
  });
}

// MARK: - Published questions (K15)

const EDITABLE_FIELDS = Object.freeze(['text', 'speech', 'choices', 'answer', 'solution']);

/**
 * `updatePublishedQuestion` `{ questionId, text?, speech?, choices?, answer?, solution? }` → `{ updatedAt }` (epoch
 * ms). The change is live at once; the id never changes. The job's draft copy is updated too, so the review screen
 * and a later single-question re-publish see the same content.
 */
export async function updatePublishedQuestionHandler(deps, request) {
  const uid = requireAdmin(request);
  const questionId = requireQuestionId(request.data?.questionId);
  const changes = validEdit(request.data);
  const now = Timestamp.fromDate(deps.now?.() ?? new Date());
  const { db } = deps;
  const questionRef = db.collection('questions').doc(questionId);

  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(questionRef);
    if (!snapshot.exists) throw new HttpsError('not-found', 'Soru bulunamadı.');
    const question = snapshot.data();
    const choices = changes.choices ?? question.choices ?? [];
    const answer = changes.answer ?? question.answer;
    if (answer?.choice && !choices.some((choice) => choice.label === answer.choice)) {
      throw new HttpsError('invalid-argument', 'Cevap şıkkı seçeneklerde yok.');
    }
    const draftRef = await draftRefOf(transaction, db, question);
    const draft = draftRef ? await transaction.get(draftRef) : null;

    transaction.update(questionRef, { ...changes, updatedAt: now });
    if (draft?.exists) transaction.update(draftRef, { ...changes, editedBy: uid, editedAt: now });
  });
  return { updatedAt: now.toMillis() };
}

/**
 * Puts one draft question live again under its permanent id (K15, after the pipeline regenerated it for a published
 * exam: payload `target: 'published'`). The query keys come from the published question, so the pools are unchanged.
 * For track 1A's pipeline (injected); not a callable.
 *
 * @returns {Promise<{ questionId: string }>}
 */
export async function publishDraftQuestion(deps, { jobId, order }) {
  const { db } = deps;
  const now = Timestamp.fromDate(deps.now?.() ?? new Date());
  const jobRef = db.collection(JOBS).doc(jobId);
  return db.runTransaction(async (transaction) => {
    const jobSnapshot = await transaction.get(jobRef);
    const examId = jobSnapshot.exists ? jobSnapshot.get('publishedExamId') : null;
    if (jobSnapshot.get?.('status') !== 'published' || !examId) throw new Error(`Job ${jobId} is not published`);
    const questionId = publishedQuestionId(examId, order);
    const [draft, published] = await transaction.getAll(
      jobRef.collection(DRAFTS).doc(questionOrderKey(order)),
      db.collection('questions').doc(questionId),
    );
    if (!draft.exists || !published.exists) throw new Error(`Question ${questionId} has no draft or published copy`);
    const data = publishedQuestion(validDraft(draft.data(), draft.id), { examId, keys: published.data(), now });
    transaction.set(published.ref, data);
    return { questionId };
  });
}

/** The draft behind a published question: `examConversions/<exam.conversionJobId>/questions/<nnn>`, or `null`. */
async function draftRefOf(transaction, db, question) {
  if (!ID_SEGMENT_PATTERN.test(question.examId ?? '')) return null;
  const exam = await transaction.get(db.collection('exams').doc(question.examId));
  const jobId = exam.exists ? exam.get('conversionJobId') : null;
  if (!JOB_ID_PATTERN.test(jobId ?? '') || !Number.isInteger(question.order)) return null;
  return db.collection(JOBS).doc(jobId).collection(DRAFTS).doc(questionOrderKey(question.order));
}

/** The admin's edit, validated with the draft rules' limits; at least one field. */
function validEdit(data) {
  const changes = {};
  if (data?.text !== undefined) changes.text = limitedText(data.text, LIMITS.text, 'Soru metni', true);
  if (data?.speech !== undefined) changes.speech = limitedText(data.speech, LIMITS.speech, 'Sesli okuma metni', false);
  if (data?.choices !== undefined) {
    if (!Array.isArray(data.choices) || data.choices.length > LIMITS.choices) throw invalid('Şıklar geçersiz.');
    changes.choices = data.choices.map((choice) => ({
      label: limitedText(choice?.label, LIMITS.choiceLabel, 'Şık etiketi', true),
      text: limitedText(choice?.text, LIMITS.choiceText, 'Şık metni', true),
    }));
    if (new Set(changes.choices.map(({ label }) => label)).size !== changes.choices.length) throw invalid('Şık etiketleri tekrar ediyor.');
  }
  if (data?.answer !== undefined) {
    const answer = data.answer;
    if (!isPlainObject(answer) || !Object.keys(answer).every((key) => ['text', 'choice', 'speech'].includes(key))) {
      throw invalid('Cevap geçersiz.');
    }
    changes.answer = {
      text: limitedText(answer.text, LIMITS.answerText, 'Cevap', true),
      ...(answer.choice !== undefined && answer.choice !== null && answer.choice !== ''
        ? { choice: limitedText(answer.choice, LIMITS.choiceLabel, 'Cevap şıkkı', true) } : {}),
      ...(answer.speech ? { speech: limitedText(answer.speech, LIMITS.speech, 'Cevabın sesli okuması', false) } : {}),
    };
  }
  if (data?.solution !== undefined) {
    if (!Array.isArray(data.solution) || data.solution.length > LIMITS.solutionSteps) throw invalid('Çözüm geçersiz.');
    changes.solution = data.solution.map((step) => limitedText(step, LIMITS.solutionStep, 'Çözüm adımı', true));
  }
  if (Object.keys(changes).length === 0) throw invalid(`Değiştirilecek alan yok (${EDITABLE_FIELDS.join(', ')}).`);
  return changes;
}

function limitedText(value, limit, what, required) {
  if (typeof value !== 'string') throw invalid(`${what} geçersiz.`);
  const trimmed = value.trim();
  if ((required && trimmed === '') || [...trimmed].length > limit) throw invalid(`${what} boş ya da çok uzun.`);
  return trimmed;
}

function invalid(message) {
  return new HttpsError('invalid-argument', message);
}

// MARK: - Exam deletion cleanup

/**
 * Removes an exam's structured data: its published questions (and their pool entries, transactionally), the
 * cropped figures (`questionFigures/<jobId>/`) and the conversion job with its drafts. The exam document and its
 * original files are the caller's (today the admin client deletes the exam). Exported for the server-side exam
 * deletion; not wired to a callable yet.
 *
 * @param {{ db: import('firebase-admin/firestore').Firestore, bucket: { deleteFiles: Function } }} deps
 * @param {string} examId
 * @param {{ jobIds?: string[] }} [options] Extra job ids (when the exam document is already gone).
 * @returns {Promise<{ questions: number, jobs: string[] }>}
 */
export async function deleteStructuredExamData(deps, examId, { jobIds = [] } = {}) {
  if (!ID_SEGMENT_PATTERN.test(examId ?? '')) throw new Error('Bad exam id');
  const { db } = deps;
  const exam = await db.collection('exams').doc(examId).get();
  const jobs = [...new Set([`exam-${examId}`, exam.exists ? exam.get('conversionJobId') : null, ...jobIds])]
    .filter((jobId) => JOB_ID_PATTERN.test(jobId ?? ''));
  const now = Timestamp.fromDate(deps.now?.() ?? new Date());

  const questions = await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(db.collection('questions').where('examId', '==', examId));
    const pools = await readPools(transaction, db, snapshot.docs.map((doc) => ({ id: doc.id, keys: doc.data(), remove: true })));
    writePools(transaction, db, pools, now);
    for (const doc of snapshot.docs) transaction.delete(doc.ref);
    return snapshot.size;
  });

  for (const jobId of jobs) {
    await deps.bucket.deleteFiles({ prefix: `questionFigures/${jobId}/` });
    await db.recursiveDelete(db.collection(JOBS).doc(jobId));
  }
  return { questions, jobs };
}

// MARK: - Input helpers

export function requireJobId(value) {
  if (typeof value !== 'string' || !JOB_ID_PATTERN.test(value)) throw invalid('İş kimliği geçersiz.');
  return value;
}

/** `<examId>-<nnn>` (`publishedQuestionId`). */
export function requireQuestionId(value) {
  const match = typeof value === 'string' ? /^(.+)-(\d{3})$/.exec(value) : null;
  if (!match || !ID_SEGMENT_PATTERN.test(match[1]) || Number(match[2]) < 1) throw invalid('Soru kimliği geçersiz.');
  return value;
}

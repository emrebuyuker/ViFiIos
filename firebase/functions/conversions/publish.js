// Publishing a reviewed conversion (the second approval, K1) and the published questions' later life (K14, K15,
// exam deletion). Contract: conversions/schema.js; data model: TODO-4.2.0 Ek A / Ek C.
//
// `publishExamConversion` runs in ONE transaction:
// - a submission job executes the submission's `publishPlan` (written by the 4.2.0 admin client at the first
//   approval): missing catalog nodes are created, existing parents get `childCount + 1`, and the exam document is
//   created. Node existence is re-read here, so a plan made stale by another publish in the meantime still keeps
//   `childCount` right; a legacy job uses the exam that already exists;
// - a DUPLICATE submission (`publishPlan.mode == 'replace'`, K22) writes nothing in the catalog: the existing exam
//   becomes structured (or gets its questions replaced) and its `files` / `kind` become the submission's copies; any
//   other active job of that exam (`exam-<examId>`) is discarded. After the transaction the previous page files (and
//   the previous job's figures) are deleted from Storage, never a file another exam still lists (files.js);
// - the drafts become `questions/<examId>-<nnn>` (published shape + denormalised query keys + `schemaVersion`);
//   questions of an earlier publish of the same exam that are no longer there are deleted;
// - `exams/<id>` gets `format: 'structured'`, `questionCount`, `structuredAt`, `conversionJobId` (its `files` are kept,
//   so 4.1.0 and Android still show the original pages);
// - the practice pools (`questionPools`, scopes tr / u- / c-, split into `__pN` parts) gain the new ids and lose the
//   removed ones; the subject (`subjects/<id>` + `catalogNodes/<courseId>.subjectId`) is resolved or created;
// - the job becomes `published` and the submission gets `publishedExamId`.
// Then, for a NEW exam from a submission, the department's "new exam" notice goes out (moved here from the first
// approval). The uploader gets nothing here (K19): their only notice is the first approval's coins notice.
//
// Subject change (K21): when the resolved subject differs from the course node's previous `subjectId`, the job records
// `subjectMove { courseId, fromSubjectId, toSubjectId, status: 'pending' }` in the transaction; afterwards EVERY
// published question of the course (`questions where courseId == X`) is moved to the new subject with its pool
// entries, in chunked transactions (`moveCourseSubject`), and the move is marked `done`. A move cut short is resumed
// by calling `publishExamConversion` again (an already published job finishes its pending move).
//
// Handlers take their dependencies (`db`, `now`, plus what `deliverNotification` needs; `bucket` for the cleanup)
// as the first argument, like the notification handlers.

import { FieldValue, Timestamp } from 'firebase-admin/firestore';
import { HttpsError } from 'firebase-functions/v2/https';
import * as logger from 'firebase-functions/logger';
import {
  ID_SEGMENT_PATTERN,
  JOB_ID_PATTERN,
  LIMITS,
  PRACTICE_EXAM_TYPES,
  QUESTION_SCHEMA_VERSION,
  parseExamTitle,
  plainSpeech,
  publishedQuestionId,
  questionOrderKey,
  questionPoolId,
} from './schema.js';
import { slug } from './slug.js';
import { resolveSubject, subjectKey } from './subjects.js';
import { DRAFTS, JOBS, cleanFiles, isPlainObject, text } from './jobs.js';
import { deleteUnreferencedArchiveFiles } from './files.js';
import { notifyNewExam } from '../notifications/automatic.js';
import { requireAdmin } from '../notifications/admin.js';

/** Ids per pool document before the next `__pN` part starts (~1 MiB / ~60 bytes per id, with headroom). */
export const POOL_PART_LIMIT = 15000;
/** Safety stop when walking a pool's parts. */
const MAX_POOL_PARTS = 50;
const SUBJECT_NAME_LIMIT = 120;
const CATALOG_LEVELS = Object.freeze(['university', 'faculty', 'department', 'course']);
/** Questions moved per transaction by a subject change (each also rewrites a few pool documents; ≤ 500 writes). */
export const SUBJECT_MOVE_CHUNK = 100;
/** Job statuses that a replacing publish (K22) ends: anything not yet terminal. */
const ACTIVE_JOB_STATUSES = Object.freeze(['queued', 'processing', 'ready', 'failed']);

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
      return {
        examId: job.publishedExamId,
        questionCount: job.questionCount ?? 0,
        alreadyPublished: true,
        subjectMove: job.subjectMove?.status === 'pending' ? job.subjectMove : null,
      };
    }
    if (job.status !== 'ready') throw new HttpsError('failed-precondition', 'Yalnızca hazır bir taslak yayınlanabilir.');

    const draftSnapshot = await transaction.get(jobRef.collection(DRAFTS).orderBy('order'));
    const drafts = draftSnapshot.docs.map((doc) => validDraft(doc.data(), doc.id));
    if (drafts.length === 0) throw new HttpsError('failed-precondition', 'Taslakta soru yok.');

    const target = job.source?.type === 'submission'
      ? await readSubmissionTarget(transaction, db, job)
      : await readLegacyTarget(transaction, db, job);
    const subject = await resolveSubject((refOrQuery) => transaction.get(refOrQuery), db, {
      courseNode: target.courseNode,
      courseName: target.names.course,
      override,
    });
    const existingQuestions = (await transaction.get(db.collection('questions').where('examId', '==', target.examId))).docs;
    const previousSubjectId = target.courseNode?.exists ? target.courseNode.get('subjectId') : null;
    const subjectMove = subject && ID_SEGMENT_PATTERN.test(previousSubjectId ?? '') && previousSubjectId !== subject.id
      && ID_SEGMENT_PATTERN.test(target.ids.course ?? '')
      ? { courseId: target.ids.course, fromSubjectId: previousSubjectId, toSubjectId: subject.id, status: 'pending' }
      : null;

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
    if (target.replace) {
      transaction.update(target.examRef, {
        format: 'structured', questionCount: questions.length, structuredAt: now, conversionJobId: jobId,
        files: target.files, kind: target.kind,
      });
      for (const other of target.otherJobs) {
        transaction.update(other.ref, { status: 'discarded', reviewedBy: uid, discardedAt: now, discardReason: 'replaced' });
      }
    } else if (target.type === 'submission') {
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
      ...(subjectMove ? { subjectMove } : {}),
    });
    if (target.type === 'submission') {
      transaction.update(target.submissionRef, { publishedExamId: target.examId });
    }
    return {
      examId: target.examId,
      questionCount: questions.length,
      // A duplicate replaces an exam the department already has: no "new exam" notice.
      notify: target.type === 'submission' && !target.replace
        ? { submissionId: target.submissionRef.id, examId: target.examId, ownerId: target.ownerId }
        : null,
      replaced: target.replace
        ? { previousFiles: target.previousFiles, files: target.files, previousJobId: target.previousJobId }
        : null,
      subjectMove,
    };
  });

  if (result.replaced) await removeReplacedFiles(deps, jobId, result.replaced);
  if (result.subjectMove) {
    try {
      await moveCourseSubject(deps, jobId, result.subjectMove);
    } catch (error) {
      // The exam is live; the job keeps `subjectMove.status: 'pending'` and a repeated publish call finishes it.
      logger.error('Moving the course to its new subject failed; publish again to resume', {
        jobId, courseId: result.subjectMove.courseId, error: error?.message ?? String(error),
      });
    }
  }
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
  if (plan.mode === 'replace') return readReplaceTarget(transaction, db, { plan, submission, submissionRef });

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

/**
 * A duplicate submission's target (`publishPlan.mode == 'replace'`, K22): the EXISTING published exam, whose ids and
 * title stay; its `files` / `kind` become the plan's copies. Also reads the exam's other job (`exam-<examId>`) to end
 * it when it is still active.
 */
async function readReplaceTarget(transaction, db, { plan, submission, submissionRef }) {
  const examRef = db.collection('exams').doc(plan.examId);
  const examSnapshot = await transaction.get(examRef);
  const exam = examSnapshot.exists ? examSnapshot.data() : null;
  if (!exam || exam.status !== 'published') {
    throw new HttpsError('failed-precondition', 'Yerine konacak sınav arşivde bulunamadı. Taslağı iptal edebilirsin.');
  }
  const files = cleanFiles(plan.exam?.files);
  const kind = plan.exam?.kind ?? submission.kind;
  if (!files || !['JPG', 'PDF'].includes(kind)) throw new HttpsError('failed-precondition', 'Gönderimin dosyaları eksik.');

  const ids = {
    university: text(exam.universityId) || plan.universityId,
    faculty: text(exam.facultyId) || plan.facultyId,
    department: text(exam.departmentId) || plan.departmentId,
    course: text(exam.courseId) || plan.courseId,
  };
  const courseNode = ID_SEGMENT_PATTERN.test(ids.course ?? '')
    ? await transaction.get(db.collection('catalogNodes').doc(ids.course))
    : null;
  const ownJobId = `sub-${submissionRef.id}`;
  const legacyJobId = `exam-${plan.examId}`;
  const otherJobs = [];
  if (JOB_ID_PATTERN.test(legacyJobId)) {
    const snapshot = await transaction.get(db.collection(JOBS).doc(legacyJobId));
    if (snapshot.exists && ACTIVE_JOB_STATUSES.includes(snapshot.get('status'))) otherJobs.push({ ref: snapshot.ref });
  }
  const previousJobId = JOB_ID_PATTERN.test(exam.conversionJobId ?? '') && exam.conversionJobId !== ownJobId
    ? exam.conversionJobId
    : null;
  return {
    type: 'submission',
    replace: true,
    examId: plan.examId,
    examRef,
    plan,
    ids,
    names: {
      course: text(exam.courseName) || text(plan.exam?.courseName) || text(submission.lesson)
        || text(courseNode?.exists ? courseNode.get('name') : ''),
      exam: text(exam.title) || text(plan.exam?.title) || text(submission.exam),
    },
    courseNode,
    submissionRef,
    ownerId: text(submission.ownerId),
    files,
    kind,
    previousFiles: Array.isArray(exam.files) ? exam.files : [],
    previousJobId,
    otherJobs,
  };
}

/**
 * After a replacing publish (K22): the exam's previous page files that the new `files` do not reuse and no exam
 * lists any more, and the figures of the job whose questions were live before. Best effort; never throws.
 */
async function removeReplacedFiles(deps, jobId, { previousFiles, files, previousJobId }) {
  if (!deps.bucket) return;
  try {
    await deleteUnreferencedArchiveFiles(deps, previousFiles, { except: files.map((file) => file.storagePath) });
    if (previousJobId && previousJobId !== jobId) {
      await deps.bucket.deleteFiles({ prefix: `questionFigures/${previousJobId}/` });
    }
  } catch (error) {
    logger.warn('Could not remove the replaced exam files', { jobId, error: error?.message ?? String(error) });
  }
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

// MARK: - Subjects (country-wide course identities, Ek C; matching in subjects.js)

export { subjectKey };

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

/** Writes the subject (new, or a learnt alias) and points the course node at it. */
function writeSubject(transaction, db, subject, target, now) {
  const ref = db.collection('subjects').doc(subject.id);
  if (subject.create) {
    transaction.create(ref, { ...subject.create, createdAt: now, updatedAt: now });
  } else if (subject.alias && !subject.aliases.includes(subject.alias)) {
    transaction.update(ref, { aliases: FieldValue.arrayUnion(subject.alias), updatedAt: now });
  }
  // A new submission's course node is written once by `writeCatalogAndExam` (created with, or updated to, the subject).
  if ((target.type === 'legacy' || target.replace) && target.courseNode?.exists
    && target.courseNode.get('subjectId') !== subject.id) {
    transaction.update(target.courseNode.ref, { subjectId: subject.id });
  }
}

// MARK: - Question pools (Ek C)

/**
 * The pool part-1 ids a published question belongs to: none without a subject or a practice-eligible exam type
 * (study materials keep their `examType` on the question but join no pool, owner decision K27).
 */
export function poolBases(keys) {
  if (!ID_SEGMENT_PATTERN.test(keys?.subjectId ?? '') || !PRACTICE_EXAM_TYPES.includes(keys?.examType)) return [];
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

// MARK: - Subject change of a course (K21)

/**
 * Moves every published question of `courseId` to `toSubjectId` (field + pool entries), `chunk` questions per
 * transaction; a question already on the new subject is skipped, so a repeated or resumed move is a no-op for it.
 * Marks the job's `subjectMove` done at the end.
 *
 * @returns {Promise<{ moved: number }>}
 */
export async function moveCourseSubject(deps, jobId, { courseId, toSubjectId }) {
  const { db } = deps;
  if (!ID_SEGMENT_PATTERN.test(courseId ?? '') || !ID_SEGMENT_PATTERN.test(toSubjectId ?? '')) throw new Error('Bad subject move');
  const now = Timestamp.fromDate(deps.now?.() ?? new Date());
  const chunk = deps.subjectMoveChunk ?? SUBJECT_MOVE_CHUNK;
  const all = await db.collection('questions').where('courseId', '==', courseId).get();
  const refs = all.docs.filter((doc) => doc.get('subjectId') !== toSubjectId).map((doc) => doc.ref);
  let moved = 0;
  for (let start = 0; start < refs.length; start += chunk) {
    const slice = refs.slice(start, start + chunk);
    moved += await db.runTransaction(async (transaction) => {
      const snapshots = (await transaction.getAll(...slice))
        .filter((snapshot) => snapshot.exists && snapshot.get('subjectId') !== toSubjectId && snapshot.get('courseId') === courseId);
      const pools = await readPools(transaction, db, snapshots.flatMap((snapshot) => [
        { id: snapshot.id, keys: snapshot.data(), remove: true },
        { id: snapshot.id, keys: { ...snapshot.data(), subjectId: toSubjectId }, remove: false },
      ]));
      writePools(transaction, db, pools, now);
      for (const snapshot of snapshots) transaction.update(snapshot.ref, { subjectId: toSubjectId });
      return snapshots.length;
    });
  }
  await db.collection(JOBS).doc(jobId).update({
    'subjectMove.status': 'done', 'subjectMove.movedCount': moved, 'subjectMove.doneAt': now,
  });
  return { moved };
}

// MARK: - discardExamConversion (K14 "Sınavı iptal et")

/**
 * `discardExamConversion` `{ jobId }` → `{ status: 'discarded' }`. A queued, ready or failed job ends for good; the
 * exam stays as it is (a legacy exam keeps its pages; a submission's exam is never published). Coins and the
 * submission record are never taken back. A running job must finish first; a published one cannot be discarded.
 * Drafts are kept for reference.
 *
 * K20: for a submission job (`sub-<id>`) the page files its first approval copied into `imagess/` / `pdfs/` (the
 * job's `files` and the plan's `exam.files`) are deleted from Storage, except a file an exam document lists.
 * Repeating the call repeats only that (idempotent) cleanup.
 */
export async function discardExamConversionHandler(deps, request) {
  const uid = requireAdmin(request);
  const jobId = requireJobId(request.data?.jobId);
  const ref = deps.db.collection(JOBS).doc(jobId);
  const now = Timestamp.fromDate(deps.now?.() ?? new Date());
  const job = await deps.db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(ref);
    if (!snapshot.exists) throw new HttpsError('not-found', 'Dönüştürme işi bulunamadı.');
    const status = snapshot.get('status');
    if (status === 'discarded') return snapshot.data();
    if (status === 'published') throw new HttpsError('failed-precondition', 'Yayınlanmış bir sınav iptal edilemez.');
    if (status === 'processing') throw new HttpsError('failed-precondition', 'Dönüştürme sürüyor; bitince iptal edebilirsin.');
    transaction.update(ref, { status: 'discarded', reviewedBy: uid, discardedAt: now });
    return snapshot.data();
  });
  if (job.source?.type === 'submission' || jobId.startsWith('sub-')) await removeDiscardedCopies(deps, jobId, job);
  return { status: 'discarded' };
}

/** K20: the copies a discarded submission job's first approval made (best effort; logged, never thrown). */
async function removeDiscardedCopies(deps, jobId, job) {
  if (!deps.bucket) return;
  try {
    const submissionId = job.source?.submissionId ?? jobId.replace(/^sub-/, '');
    const submission = ID_SEGMENT_PATTERN.test(submissionId)
      ? await deps.db.collection('submissions').doc(submissionId).get()
      : null;
    const planFiles = submission?.exists ? submission.get('publishPlan')?.exam?.files : null;
    const files = [...(Array.isArray(job.files) ? job.files : []), ...(Array.isArray(planFiles) ? planFiles : [])];
    const { deleted } = await deleteUnreferencedArchiveFiles(deps, files);
    if (deleted.length > 0) logger.info('Removed the copies of a discarded submission', { jobId, deleted: deleted.length });
  } catch (error) {
    logger.warn('Could not remove the copies of a discarded submission', { jobId, error: error?.message ?? String(error) });
  }
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
 * original files are the caller's (the admin client deletes the exam). Runs from the `onExamDeleted` trigger, i.e.
 * after the exam document is gone, so the job ids come from the jobs themselves (`publishedExamId`) as well as the
 * exam document when it still exists. Idempotent; a plain (non-structured) exam is a no-op.
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
  const linked = await db.collection(JOBS).where('publishedExamId', '==', examId).get();
  const jobs = [...new Set([`exam-${examId}`, exam.exists ? exam.get('conversionJobId') : null, ...linked.docs.map((doc) => doc.id), ...jobIds])]
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

/** `onExamDeleted` (Firestore `exams/{examId}` delete): cleans the deleted exam's structured data. */
export async function onExamDeletedHandler(deps, event) {
  const examId = event.params?.examId;
  if (!ID_SEGMENT_PATTERN.test(examId ?? '')) return null;
  return deleteStructuredExamData(deps, examId);
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

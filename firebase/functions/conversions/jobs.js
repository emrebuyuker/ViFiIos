// Conversion jobs (`examConversions/{jobId}`, contract: conversions/schema.js): building the job document for a
// legacy archive exam or an approved submission, claiming a job for a (re-)run and handing it to the queue.
//
// Shared by the admin callables (`admin.js`, `publish.js`) and the moderation trigger (`notifications/automatic.js`),
// so neither imports the other. The queue itself (`processExamConversion`, the AI pipeline) is track 1A's; here it is
// only the injected `deps.enqueueConversion(jobId, options)`, whose task payload is `{ jobId, ...options }`:
// - `{ jobId }`                                         whole exam; the provider is the job's `model.provider`.
// - `{ jobId, order, provider, target: 'draft' }`       one draft question (K8); the job stays `ready`.
// - `{ jobId, order, provider, target: 'published' }`   one published question (K15): the pipeline rewrites the
//   draft question, then calls `publishDraftQuestion(deps, { jobId, order })` (publish.js) to put it live.

import { FieldValue } from 'firebase-admin/firestore';
import { HttpsError } from 'firebase-functions/v2/https';
import * as logger from 'firebase-functions/logger';
import { ID_SEGMENT_PATTERN, PROVIDERS, canonicalExamTitle, conversionJobId } from './schema.js';
import { suggestSubject } from './subjects.js';

export const JOBS = 'examConversions';
export const DRAFTS = 'questions';

const EXAM_KINDS = Object.freeze(['JPG', 'PDF']);

/** A provider id from a request, or `invalid-argument` (there is no default, K9). */
export function requireProvider(value) {
  if (!PROVIDERS.includes(value)) throw new HttpsError('invalid-argument', 'Yapay zekâ modeli seçilmeli (claude ya da gemini).');
  return value;
}

/** Whether a job is waiting for an admin to pick a provider (the job of a 4.1.0 approval, or one without a choice). */
export function isWaitingForProvider(job) {
  return job?.status === 'queued' && !PROVIDERS.includes(job?.model?.provider);
}

/**
 * When a whole-exam run may be (re-)started, per caller:
 * - `request`    (`requestExamConversion`, one exam): no job yet, waiting for a provider, failed or discarded. An
 *                active job (queued with a provider, processing, ready) and a published one are returned as is.
 * - `bulk`       (`requestBulkConversion`): only no job yet or waiting for a provider — a bulk run never re-spends on
 *                a failed or discarded exam and never replaces a draft awaiting review.
 * - `regenerate` (`regenerateExamConversion`, K14): an existing job that is ready, failed or waiting for a provider.
 */
export const RUN_POLICIES = Object.freeze({
  request: (job) => !job || isIdle(job) || job.status === 'failed' || job.status === 'discarded',
  bulk: (job) => !job || isIdle(job),
  regenerate: (job) => Boolean(job) && (isIdle(job) || job.status === 'ready' || job.status === 'failed'),
});

/** `queued` but never handed to the pipeline: no provider picked yet, or the enqueue failed (`enqueue:` error). */
export function isIdle(job) {
  return isWaitingForProvider(job)
    || (job?.status === 'queued' && typeof job?.error === 'string' && job.error.startsWith(ENQUEUE_ERROR_PREFIX));
}

const ENQUEUE_ERROR_PREFIX = 'enqueue:';

/** `[{ storagePath, order }]` sorted by order; `null` when the list is empty or has an unusable entry. */
export function cleanFiles(files) {
  if (!Array.isArray(files) || files.length === 0) return null;
  const cleaned = files
    .filter((file) => typeof file?.storagePath === 'string' && file.storagePath.length > 0)
    .map((file) => ({ storagePath: file.storagePath, order: Number.isInteger(file.order) ? file.order : 0 }))
    .sort((a, b) => a.order - b.order);
  return cleaned.length === files.length ? cleaned : null;
}

/** The job for a published archive exam (`exam-<examId>`); `null` when the exam cannot be converted. */
export function legacyJob(examId, exam, { provider = null, requestedBy = 'system', budget = null } = {}) {
  const files = cleanFiles(exam?.files);
  if (!files || !EXAM_KINDS.includes(exam?.kind)) return null;
  return baseJob({
    source: { type: 'legacy', examId },
    placement: {
      examId,
      universityId: text(exam.universityId),
      facultyId: text(exam.facultyId),
      departmentId: text(exam.departmentId),
      courseId: text(exam.courseId),
      names: [exam.universityName, exam.facultyName, exam.departmentName, exam.courseName, exam.title].map(text),
      ...titleSuggestion(exam.title),
    },
    files,
    kind: exam.kind,
    provider,
    requestedBy,
    budget,
  });
}

/**
 * The job for an approved 4.2.0 submission (`sub-<submissionId>`), from its `publishPlan`: the exam's future ids and
 * the files the first approval already copied into the public archive storage (`pending/` is deleted with the
 * account). The provider is the admin's first-approval choice (`conversionProvider`); `null` when the plan is unusable.
 */
export function submissionJob(submissionId, submission) {
  const plan = submission?.publishPlan;
  const files = cleanFiles(plan?.exam?.files);
  const kind = plan?.exam?.kind ?? submission?.kind;
  if (!isPlainObject(plan) || !ID_SEGMENT_PATTERN.test(plan.examId ?? '') || !files || !EXAM_KINDS.includes(kind)) {
    return null;
  }
  const provider = PROVIDERS.includes(submission.conversionProvider) ? submission.conversionProvider : null;
  return baseJob({
    source: { type: 'submission', submissionId },
    placement: {
      examId: plan.examId,
      universityId: text(plan.universityId),
      facultyId: text(plan.facultyId),
      departmentId: text(plan.departmentId),
      courseId: text(plan.courseId),
      names: [submission.university, submission.faculty, submission.department, submission.lesson, submission.exam].map(text),
      ...titleSuggestion(plan.exam?.title ?? submission.exam),
    },
    files,
    kind,
    provider,
    // The approving admin is not recorded on the submission; the trigger acts for them.
    requestedBy: 'system',
  });
}

/**
 * `placement.originalTitle` (the archive / submitted exam title, kept for the admin) and `placement.suggestedTitle`
 * (its list title, owner decision K28; `null` when no list name matches and the admin has to pick one).
 */
export function titleSuggestion(title) {
  const originalTitle = text(title);
  return { originalTitle, suggestedTitle: canonicalExamTitle(originalTitle)?.title ?? null };
}

/**
 * The job with the suggested subject added to its placement (`placement.subjectId` / `placement.subjectName`, read by
 * the admin review screen): what an automatic publish would resolve the course to now (subjects.js). Best effort —
 * a failed lookup leaves the job without a suggestion; publishing resolves the subject again either way.
 */
export async function withSubjectSuggestion(db, job) {
  if (!job) return job;
  try {
    const subject = await suggestSubject(db, { courseId: job.placement.courseId, courseName: job.placement.names[3] });
    if (subject) job.placement = { ...job.placement, ...subject };
  } catch (error) {
    logger.warn('Could not suggest a subject for a conversion job', { error: error?.message ?? String(error) });
  }
  return job;
}

/**
 * The job document. `budget: 'oneTime'` (K12c, only the one-time migration script) keeps the job's runs out of the
 * monthly cap (usage.js); absent = the regular monthly budget.
 */
function baseJob({ source, placement, files, kind, provider, requestedBy, budget = null }) {
  return {
    ...(budget === 'oneTime' ? { budget } : {}),
    source,
    placement,
    files,
    kind,
    status: 'queued',
    attempts: 0,
    error: null,
    model: provider ? { provider, id: null } : null,
    usage: null,
    requestedBy,
    reviewedBy: null,
    createdAt: FieldValue.serverTimestamp(),
    requestedAt: FieldValue.serverTimestamp(),
    readyAt: null,
    publishedAt: null,
  };
}

/**
 * The fields that put an existing job back to `queued` for a fresh whole-exam run with `provider`. The run's budget
 * is the restarter's: the script's `oneTime`, else the regular monthly one (an admin re-run is never one-time).
 */
export function restartFields(provider, requestedBy, budget = null) {
  return {
    budget: budget === 'oneTime' ? budget : FieldValue.delete(),
    status: 'queued',
    attempts: 0,
    error: null,
    model: { provider, id: null },
    requestedBy,
    requestedAt: FieldValue.serverTimestamp(),
    readyAt: null,
  };
}

/**
 * Starts (or restarts) the whole-exam run of job `jobId` with `provider`, transactionally: when `policy` refuses the
 * current job it is returned untouched (`started: false`); a missing job is created from `await create()` (`null` →
 * `failed-precondition`). Only the call that claimed the run clears the old drafts and enqueues it.
 *
 * @returns {Promise<{ jobId: string, status: string, started: boolean }>}
 */
export async function startRun(deps, jobId, { provider, requestedBy, policy, create, budget = null }) {
  const ref = deps.db.collection(JOBS).doc(jobId);
  const outcome = await deps.db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(ref);
    const job = snapshot.exists ? snapshot.data() : null;
    if (!policy(job)) {
      if (!job) throw new HttpsError('not-found', 'Dönüştürme işi bulunamadı.');
      return { status: job.status, started: false };
    }
    if (job) {
      transaction.update(ref, restartFields(provider, requestedBy, budget));
    } else {
      const fresh = await create?.();
      if (!fresh) throw new HttpsError('failed-precondition', 'Sınavın dosyaları dönüştürmeye uygun değil.');
      transaction.create(ref, fresh);
    }
    return { status: 'queued', started: true };
  });
  if (outcome.started) {
    await clearDrafts(deps.db, jobId);
    await enqueue(deps, jobId);
  }
  return { jobId, ...outcome };
}

/** `startRun` for a published archive exam's job `exam-<examId>` (`budget: 'oneTime'` only from the K12c script). */
export function startLegacyRun(deps, examId, exam, { provider, requestedBy, policy, budget = null }) {
  return startRun(deps, conversionJobId({ type: 'legacy', examId }), {
    provider,
    requestedBy,
    policy,
    budget,
    create: () => withSubjectSuggestion(deps.db, legacyJob(examId, exam, { provider, requestedBy, budget })),
  });
}

/**
 * Hands a job (or one of its questions) to the queue; a failure surfaces as `unavailable`. A whole run that cannot
 * be enqueued stays `queued` with an `enqueue:` error, which lets an admin start it again (`isIdle`).
 */
export async function enqueue(deps, jobId, options = {}) {
  try {
    await deps.enqueueConversion(jobId, options);
  } catch (error) {
    // Only a whole run leaves the job `queued`; a single-question request leaves no trace (the admin just retries).
    if (Object.keys(options).length > 0) throw new HttpsError('unavailable', 'Soru kuyruğa alınamadı. Lütfen tekrar dene.');
    await deps.db.collection(JOBS).doc(jobId)
      .update({ error: `${ENQUEUE_ERROR_PREFIX} ${String(error?.message ?? error).slice(0, 400)}` })
      .catch(() => {});
    throw new HttpsError('unavailable', 'Dönüştürme kuyruğa alınamadı. Lütfen tekrar dene.');
  }
}

/** Deletes a job's draft questions (a fresh whole-exam run writes a new set; stale higher orders must not linger). */
export async function clearDrafts(db, jobId) {
  const drafts = await db.collection(JOBS).doc(jobId).collection(DRAFTS).listDocuments();
  if (drafts.length === 0) return;
  const writer = db.bulkWriter();
  for (const ref of drafts) writer.delete(ref);
  await writer.close();
}

export function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

export function text(value) {
  return typeof value === 'string' ? value.trim() : '';
}

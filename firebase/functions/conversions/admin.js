// The structured-exam admin callables (contract: `CALLABLES` in conversions/schema.js). Every one requires the
// `admin: true` claim (checked before any dependency is touched) and every AI-running one an explicit `provider`
// ('claude' | 'gemini', K9 — no default).
//
// Starting AI work only claims the job (a transaction) and enqueues it through the injected
// `deps.enqueueConversion(jobId, options)`; the queue function `processExamConversion` (the AI pipeline) is track
// 1A's. Publishing, discarding and editing published questions live in `publish.js` and are re-exported here, so
// `index.js` wires all eight from this module.
//
// Handlers take their dependencies (`db`, `enqueueConversion`, `now`, plus what `deliverNotification` needs for
// the publish-time department notice) as the first argument; `index.js` wires the live ones.

import { HttpsError } from 'firebase-functions/v2/https';
import { ID_SEGMENT_PATTERN, conversionJobId, questionOrderKey } from './schema.js';
import { DRAFTS, JOBS, RUN_POLICIES, enqueue, legacyJob, requireProvider, startLegacyRun, startRun } from './jobs.js';
import { requireJobId, requireQuestionId } from './publish.js';
import { requireAdmin } from '../notifications/admin.js';

export {
  discardExamConversionHandler,
  publishExamConversionHandler,
  updatePublishedQuestionHandler,
} from './publish.js';

/**
 * Rough AI cost per page by provider, for the bulk estimate only (the pipeline records the real `usage`).
 * TODO(4.2.0 Faz 2): replace with the providers' current Vertex AI prices (TODO-4.2.0: a 4–5 page exam ≈ $0.35–0.65
 * with Claude Opus 5.5, ≈ $0.20–0.40 with Gemini Pro) once measured on real exams.
 */
export const ESTIMATED_COST_PER_PAGE_USD = Object.freeze({ claude: 0.13, gemini: 0.08 });
/** A PDF's page count is unknown until it is opened; each PDF file is estimated at this many pages. */
export const ESTIMATED_PAGES_PER_PDF = 4;
/** At most this many exams per bulk request (a department larger than this is queued course by course). */
export const BULK_LIMIT = 200;

/**
 * `requestExamConversion` `{ examId, provider }` → `{ jobId, status }`: the legacy "Yeni yapıya geçir" button. An
 * active job (queued with a provider, processing, ready) or a published one is returned as is; a new, waiting,
 * failed or discarded one is (re)started with `provider`.
 */
export async function requestExamConversionHandler(deps, request) {
  const uid = requireAdmin(request);
  const examId = requireExamId(request.data?.examId);
  const provider = requireProvider(request.data?.provider);

  const snapshot = await deps.db.collection('exams').doc(examId).get();
  if (!snapshot.exists || snapshot.get('status') !== 'published') throw new HttpsError('not-found', 'Sınav bulunamadı.');
  const exam = snapshot.data();
  if (exam.format === 'structured') {
    return { jobId: exam.conversionJobId ?? conversionJobId({ type: 'legacy', examId }), status: 'published' };
  }
  const { jobId, status } = await startLegacyRun(deps, examId, exam, { provider, requestedBy: uid, policy: RUN_POLICIES.request });
  return { jobId, status };
}

/**
 * `requestBulkConversion` `{ courseId | departmentId, provider, dryRun }` → `{ examCount, estimatedCostUsd, jobIds }`
 * (K12b). Covers the published, not yet structured exams of one course or department that have no job yet (or one
 * waiting for a provider) — failed, discarded and in-review exams are left to their own screens. Only an explicit
 * `dryRun: false` starts anything; a dry run returns the estimate with no job ids.
 */
export async function requestBulkConversionHandler(deps, request) {
  const uid = requireAdmin(request);
  const data = request.data ?? {};
  const scopes = ['courseId', 'departmentId'].filter((key) => data[key] !== undefined && data[key] !== null);
  if (scopes.length !== 1) throw new HttpsError('invalid-argument', 'Ya bir ders ya da bir bölüm seçilmeli.');
  const field = scopes[0];
  const scopeId = requireExamId(data[field]);
  const provider = requireProvider(data.provider);
  const dryRun = data.dryRun !== false;

  const exams = (await deps.db.collection('exams').where(field, '==', scopeId).get()).docs
    .filter((doc) => doc.get('status') === 'published' && doc.get('format') !== 'structured')
    .filter((doc) => legacyJob(doc.id, doc.data()) !== null);
  const jobRefs = exams.map((doc) => deps.db.collection(JOBS).doc(conversionJobId({ type: 'legacy', examId: doc.id })));
  const jobs = jobRefs.length > 0 ? await deps.db.getAll(...jobRefs) : [];
  const candidates = exams.filter((doc, index) => RUN_POLICIES.bulk(jobs[index].exists ? jobs[index].data() : null));
  if (candidates.length > BULK_LIMIT) {
    throw new HttpsError('failed-precondition', `Bu seçimde ${candidates.length} sınav var; en çok ${BULK_LIMIT}. Ders ders kuyruğa al.`);
  }

  const estimatedCostUsd = Math.round(
    candidates.reduce((sum, doc) => sum + estimatedPages(doc.data()), 0) * ESTIMATED_COST_PER_PAGE_USD[provider] * 100,
  ) / 100;
  if (dryRun) return { examCount: candidates.length, estimatedCostUsd, jobIds: [] };

  const jobIds = [];
  for (const doc of candidates) {
    // Sequential: each start is its own transaction + enqueue; a re-sent request skips what already started.
    const result = await startLegacyRun(deps, doc.id, doc.data(), { provider, requestedBy: uid, policy: RUN_POLICIES.bulk });
    if (result.started) jobIds.push(result.jobId);
  }
  return { examCount: candidates.length, estimatedCostUsd, jobIds };
}

/** Pages the AI will read: one per image, `ESTIMATED_PAGES_PER_PDF` per PDF file. */
export function estimatedPages(exam) {
  const files = Array.isArray(exam?.files) ? exam.files.length : 0;
  return exam?.kind === 'PDF' ? files * ESTIMATED_PAGES_PER_PDF : files;
}

/**
 * `regenerateExamConversion` `{ jobId, provider }` → `{ status }` (K14 "tümünü yeniden üret", a failed job's retry,
 * or starting a job that waits for a provider). The old drafts are removed; a running, published or discarded job
 * is refused.
 */
export async function regenerateExamConversionHandler(deps, request) {
  const uid = requireAdmin(request);
  const jobId = requireJobId(request.data?.jobId);
  const provider = requireProvider(request.data?.provider);
  const result = await startRun(deps, jobId, { provider, requestedBy: uid, policy: RUN_POLICIES.regenerate });
  if (!result.started) {
    throw new HttpsError('failed-precondition', `Bu iş şu an yeniden üretilemez (durum: ${result.status}).`);
  }
  return { status: result.status };
}

/**
 * `regenerateDraftQuestion` `{ jobId, order, provider }` → `{ status: 'queued' }` (K8): one draft question of a job
 * awaiting review is rewritten by the pipeline; the job stays `ready`.
 */
export async function regenerateDraftQuestionHandler(deps, request) {
  requireAdmin(request);
  const jobId = requireJobId(request.data?.jobId);
  const order = requireOrder(request.data?.order);
  const provider = requireProvider(request.data?.provider);

  const jobRef = deps.db.collection(JOBS).doc(jobId);
  const [job, draft] = await deps.db.getAll(jobRef, jobRef.collection(DRAFTS).doc(questionOrderKey(order)));
  if (!job.exists) throw new HttpsError('not-found', 'Dönüştürme işi bulunamadı.');
  if (job.get('status') !== 'ready') throw new HttpsError('failed-precondition', 'Yalnızca incelemedeki bir taslağın sorusu yeniden üretilebilir.');
  if (!draft.exists) throw new HttpsError('not-found', 'Taslak soru bulunamadı.');
  await enqueue(deps, jobId, { order, provider, target: 'draft' });
  return { status: 'queued' };
}

/**
 * `regeneratePublishedQuestion` `{ questionId, provider }` → `{ status: 'queued' }` (K15): the pipeline rewrites the
 * question's draft and puts it live under the same id (`publishDraftQuestion`).
 */
export async function regeneratePublishedQuestionHandler(deps, request) {
  requireAdmin(request);
  const questionId = requireQuestionId(request.data?.questionId);
  const provider = requireProvider(request.data?.provider);

  const question = await deps.db.collection('questions').doc(questionId).get();
  if (!question.exists) throw new HttpsError('not-found', 'Soru bulunamadı.');
  const examId = question.get('examId');
  const order = question.get('order');
  const exam = ID_SEGMENT_PATTERN.test(examId ?? '') ? await deps.db.collection('exams').doc(examId).get() : null;
  const jobId = exam?.exists ? exam.get('conversionJobId') : null;
  if (typeof jobId !== 'string' || !Number.isInteger(order)) {
    throw new HttpsError('failed-precondition', 'Sorunun dönüştürme işi bulunamadı.');
  }
  const jobRef = deps.db.collection(JOBS).doc(jobId);
  const [job, draft] = await deps.db.getAll(jobRef, jobRef.collection(DRAFTS).doc(questionOrderKey(order)));
  if (!job.exists || job.get('status') !== 'published' || !draft.exists) {
    throw new HttpsError('failed-precondition', 'Sorunun dönüştürme taslağı bulunamadı.');
  }
  await enqueue(deps, jobId, { order, provider, target: 'published' });
  return { status: 'queued' };
}

// MARK: - Input helpers

function requireExamId(value) {
  if (typeof value !== 'string' || !ID_SEGMENT_PATTERN.test(value)) throw new HttpsError('invalid-argument', 'Kimlik geçersiz.');
  return value;
}

function requireOrder(value) {
  if (!Number.isInteger(value) || value < 1 || value > 999) throw new HttpsError('invalid-argument', 'Soru sırası geçersiz.');
  return value;
}

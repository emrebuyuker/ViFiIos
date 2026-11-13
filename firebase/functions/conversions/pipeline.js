// The AI conversion pipeline (4.2.0 Faz 1A + Faz 2): one exam's files → the admin-picked model on Vertex AI →
// validated draft questions with cropped figures under `examConversions/{jobId}/questions/{nnn}` → `ready` (+ an
// admin notice). Also rewrites ONE question of a job on request (K8 draft, K15 published).
//
// `processExamConversionHandler` is the body of the Cloud Tasks queue function `processExamConversion` (index.js):
//
//   export const processExamConversion = onTaskDispatched(TASK_QUEUE_OPTIONS, (request) =>
//     processExamConversionHandler(conversionDeps, { ...request.data, retryCount: request.retryCount }));
//
// Task payloads (enqueued by conversions/jobs.js `enqueue`):
// - `{ jobId }`                                        the whole exam with the job's `model.provider`.
// - `{ jobId, order, provider, target: 'draft' }`      one draft question of a `ready` job (K8); the job stays `ready`.
// - `{ jobId, order, provider, target: 'published' }`  one question of a `published` job (K15): the draft is rewritten
//   and then put live under its permanent id with `publishDraftQuestion` (publish.js); the job stays `published`.
//
// Whole-exam flow: claim the job in one transaction (only `queued` / `processing` with `model.provider`; the monthly
// cap of usage.js checked against `aiUsage/{YYYY-MM}`; status → `processing`, `attempts` + 1, a lease) → download the
// files → `provider.solveExam` → record the run's usage and cost (job + month, even when the answer is then rejected)
// → `validateModelOutput` → crop figures into `questionFigures/{jobId}/{nnn}-{k}.jpg` → in ONE transaction, only
// while the job is still `processing`: write the drafts (stale ones from an earlier run removed) + `ready` +
// `readyAt` → `deps.notifyAdmins({ trigger: conversionReady, … })`. A job discarded (or published) meanwhile keeps
// its drafts untouched.
//
// Single-question flow: claim the draft (job must be `ready` for `draft`, `published` for `published`; the same
// monthly cap; a lease on the draft, `regenerationLeaseUntil`) → the same files to the chosen provider with
// `focus: { label, order }` (same SYSTEM_PROMPT and schema, plus an instruction naming the question) → usage recorded
// like a normal run → validate → crop that question's figures → replace only that draft (one transaction, only while
// the job is still in the expected status; `needsReviewCount` recomputed) → for `published`, `publishDraftQuestion`.
// Job `status` and `attempts` are not touched. Over the cap the request is dropped (the admin gets the month's single
// budget notice and can ask again next month); after its last attempt the draft keeps its content and gets
// `regenerationError`.
//
// Failures (whole exam): a retryable error (model/network/invalid output) is re-thrown so Cloud Tasks retries the
// task; on the last attempt, or for a permanent error (missing files, unknown file type), the job becomes `failed`
// with `error` and the admins get `conversionFailed`. A job over the monthly cap stays `queued` (one admin notice per
// month, `conversionBudgetExceeded`) and, when `deps.enqueue` is wired, is re-enqueued for the start of next month. A
// re-delivered task for a job that is already `ready` / `failed` / `published` / `discarded` does nothing.
//
// Dependencies (`deps`): `db` (Firestore `vifi`), `bucket` (Storage), `getProvider(name)` (providers/index.js
// `liveProviders()`, a fake in tests), `notifyAdmins({ trigger, jobId, attempts, … })` (automatic.js
// `notifyAdminsAboutConversion`), optional `now()`, `enqueue(data, { scheduleTime })`, `pdf: { pageCount(bytes),
// renderPage(bytes, pageIndex) }` (a PDF rasteriser — none is bundled yet, see images.js), `maxAttempts`, `capUsd`.

import { FieldValue } from 'firebase-admin/firestore';
import * as logger from 'firebase-functions/logger';
import { TRIGGERS } from '../notifications/automatic.js';
import { PROMPT_VERSION } from './prompt.js';
import { publishDraftQuestion } from './publish.js';
import {
  JOB_ID_PATTERN,
  LIMITS,
  PROVIDERS,
  QUESTION_SCHEMA_VERSION,
  figureStoragePath,
  questionOrderKey,
  usageMonthKey,
  validateModelOutput,
} from './schema.js';
import {
  MONTHLY_CAP_USD,
  addUsage,
  claimCapNotice,
  costUsd,
  estimateJobCostUsd,
  isOverCap,
  jobBudget,
  nextMonthStart,
  spentUsd,
  usageRef,
} from './usage.js';
import { cropFigure, normalizePageImage, pdfPageCount } from './images.js';

export const CONVERSIONS_COLLECTION = 'examConversions';
export const DRAFTS_COLLECTION = 'questions';

/** Options for `onTaskDispatched` (Cloud Tasks queue `processExamConversion`). */
export const TASK_QUEUE_OPTIONS = Object.freeze({
  region: 'europe-west1',
  timeoutSeconds: 1800,
  memory: '2GiB',
  // Cloud Tasks retries a task whose handler throws; the handler fails the job itself on the last attempt.
  retryConfig: Object.freeze({ maxAttempts: 3, minBackoffSeconds: 120, maxBackoffSeconds: 1800 }),
  // Concurrency limit: at most 3 exams in flight (Vertex quota, memory, and the cap's worst-case overshoot).
  rateLimits: Object.freeze({ maxConcurrentDispatches: 3, maxDispatchesPerSecond: 1 }),
});

/** A claimed job is leased for the function timeout plus a margin, so a duplicate delivery does not run it twice. */
export const LEASE_MS = (TASK_QUEUE_OPTIONS.timeoutSeconds + 120) * 1000;

/** Single-question payload `target` → the job status it requires (and keeps). */
export const QUESTION_TARGETS = Object.freeze({ draft: 'ready', published: 'published' });

/** Cloud Tasks can schedule at most 30 days ahead; a budget deferral re-checks at least this often. */
const MAX_SCHEDULE_AHEAD_MS = 29 * 24 * 60 * 60 * 1000;
const ERROR_LIMIT = 500;

/** The `trigger` passed to `deps.notifyAdmins` (all three are automatic.js `TRIGGERS`). */
export const PIPELINE_NOTICES = Object.freeze({
  ready: TRIGGERS.conversionReady,
  failed: TRIGGERS.conversionFailed,
  budgetExceeded: TRIGGERS.conversionBudgetExceeded,
});

/** A pipeline failure; `retryable: false` fails the job at once instead of waiting for the task queue's retries. */
export class PipelineError extends Error {
  constructor(code, message, { retryable = true } = {}) {
    super(message);
    this.name = 'PipelineError';
    this.code = code;
    this.retryable = retryable;
  }
}

const jobRef = (db, jobId) => db.collection(CONVERSIONS_COLLECTION).doc(jobId);
const draftRef = (db, jobId, order) => jobRef(db, jobId).collection(DRAFTS_COLLECTION).doc(questionOrderKey(order));

export async function processExamConversionHandler(deps, { jobId, order, provider, target, retryCount = 0 } = {}) {
  const now = clock(deps)();
  if (!JOB_ID_PATTERN.test(jobId ?? '')) return { outcome: 'skipped', reason: 'bad-job-id' };
  const maxAttempts = deps.maxAttempts ?? TASK_QUEUE_OPTIONS.retryConfig.maxAttempts;
  const isFinalAttempt = (Number(retryCount) || 0) + 1 >= maxAttempts;
  if (order !== undefined && order !== null) {
    return processQuestion(deps, { jobId, order, provider, target, isFinalAttempt, now });
  }

  const claim = await claimJob(deps, jobId, now);
  if (claim.outcome === 'skipped') return claim;
  if (claim.outcome === 'leased') {
    // Another delivery is running this job. On the last attempt let that run finish (or fail) the job.
    if (isFinalAttempt) return { outcome: 'skipped', reason: 'leased' };
    throw new PipelineError('lease-held', `Job ${jobId} is being processed by another task`);
  }
  if (claim.outcome === 'deferred') {
    await deferForBudget(deps, jobId, claim, now);
    return claim;
  }

  try {
    return await runConversion(deps, jobId, claim);
  } catch (error) {
    if (error?.retryable !== false && !isFinalAttempt) {
      await releaseForRetry(deps, jobId, error);
      throw error;
    }
    return failJob(deps, jobId, error);
  }
}

// MARK: - Claim

/** `{ deferred… }` when starting a monthly-budget run now would break the cap, else `null` (transaction reads). */
async function checkCap(tx, deps, { job, provider, now }) {
  if (jobBudget(job) !== 'monthly') return null;
  const capUsd = deps.capUsd ?? MONTHLY_CAP_USD;
  const month = usageMonthKey(now);
  const usage = await tx.get(usageRef(deps.db, month));
  const spent = spentUsd(usage);
  const estimate = estimateJobCostUsd({ provider, pageCount: Array.isArray(job.files) ? job.files.length : 1 });
  if (!isOverCap({ spentUsd: spent, estimateUsd: estimate, capUsd })) return null;
  return { month, spentUsd: spent, capUsd };
}

/** The job's `usage` map, created when the job has none yet (`null` on a fresh job), so the increments can nest. */
const usageInit = (job) => (isMap(job.usage) ? {} : { usage: { inputTokens: 0, outputTokens: 0, costUsd: 0 } });

async function claimJob(deps, jobId, now) {
  const { db } = deps;
  const ref = jobRef(db, jobId);
  return db.runTransaction(async (tx) => {
    const snapshot = await tx.get(ref);
    if (!snapshot.exists) return { outcome: 'skipped', reason: 'missing' };
    const job = snapshot.data();
    if (!['queued', 'processing'].includes(job.status)) return { outcome: 'skipped', reason: `status-${job.status}` };
    const provider = job.model?.provider;
    if (!PROVIDERS.includes(provider)) return { outcome: 'skipped', reason: 'no-provider' };
    const leaseUntil = job.leaseUntil?.toDate?.() ?? null;
    if (job.status === 'processing' && leaseUntil && leaseUntil > now) return { outcome: 'leased' };

    const month = usageMonthKey(now);
    const budget = jobBudget(job);
    const overCap = await checkCap(tx, deps, { job, provider, now });
    if (overCap) {
      const deferredUntil = nextMonthStart(now);
      tx.update(ref, {
        status: 'queued', budgetDeferredMonth: month, deferredUntil, leaseUntil: FieldValue.delete(),
      });
      return { outcome: 'deferred', jobId, ...overCap, deferredUntil, attempts: job.attempts ?? 0 };
    }

    const modelId = deps.getProvider(provider).modelId;
    tx.update(ref, {
      status: 'processing',
      attempts: FieldValue.increment(1),
      processingAt: now,
      leaseUntil: new Date(now.getTime() + LEASE_MS),
      model: { provider, id: modelId },
      promptVersion: PROMPT_VERSION,
      error: FieldValue.delete(),
      budgetDeferredMonth: FieldValue.delete(),
      deferredUntil: FieldValue.delete(),
      ...usageInit(job),
    });
    return { outcome: 'claimed', job, provider, modelId, month, budget, attempts: (job.attempts ?? 0) + 1 };
  });
}

/** The month's single "budget reached" notice (claimed on `aiUsage/{month}`); never fails the caller. */
async function noticeBudget(deps, jobId, claim, now) {
  try {
    if (await claimCapNotice(deps.db, claim.month, now)) {
      await notify(deps, {
        trigger: PIPELINE_NOTICES.budgetExceeded, jobId, attempts: claim.attempts ?? 0,
        month: claim.month, spentUsd: claim.spentUsd, capUsd: claim.capUsd,
      });
    }
  } catch (error) {
    logger.error('Could not send the AI budget notice', { jobId, month: claim.month, error: String(error) });
  }
}

async function deferForBudget(deps, jobId, claim, now) {
  await noticeBudget(deps, jobId, claim, now);
  if (!deps.enqueue) return;
  const scheduleTime = new Date(Math.min(claim.deferredUntil.getTime(), now.getTime() + MAX_SCHEDULE_AHEAD_MS));
  try {
    await deps.enqueue({ jobId }, { scheduleTime });
  } catch (error) {
    // The job stays `queued`; an admin restart (or a later enqueue) picks it up.
    logger.error('Could not re-enqueue a budget-deferred conversion', { jobId, error: String(error) });
  }
}

// MARK: - Run (whole exam)

async function runConversion(deps, jobId, claim) {
  const { db, bucket } = deps;
  const { job, provider: providerName, modelId, month, budget, attempts } = claim;
  const exam = await loadExam(deps, job);
  const { usage, questions, unreadable } = await solve(deps, jobId, { job, exam, providerName, month, budget });

  // Discarded meanwhile: do not even overwrite the figures its kept drafts point at.
  if (!(await jobHasStatus(db, jobId, 'processing'))) return { outcome: 'abandoned', jobId };
  const meta = { providerName, modelId, now: clock(deps)() };
  const drafts = [];
  const figurePaths = new Set();
  for (const question of questions) {
    const { draft, paths } = await buildDraft(deps, exam, jobId, question, question.order, meta);
    drafts.push(draft);
    paths.forEach((path) => figurePaths.add(path));
  }

  const readyAt = clock(deps)();
  const collection = jobRef(db, jobId).collection(DRAFTS_COLLECTION);
  const finished = await db.runTransaction(async (tx) => {
    const ref = jobRef(db, jobId);
    const snapshot = await tx.get(ref);
    // An admin discarded (or restarted) the job meanwhile: leave its new state — and its drafts — alone.
    if (!snapshot.exists || snapshot.get('status') !== 'processing') return false;
    const existing = await tx.get(collection);
    const keep = new Set(drafts.map((draft) => questionOrderKey(draft.order)));
    // ≤ 150 sets + the stale deletes + 1 update stay under the 500-write transaction limit.
    for (const draft of drafts) tx.set(collection.doc(questionOrderKey(draft.order)), draft);
    for (const doc of existing.docs) if (!keep.has(doc.id)) tx.delete(doc.ref);
    tx.update(ref, {
      status: 'ready',
      readyAt,
      pageCount: exam.pageCount,
      questionCount: drafts.length,
      needsReviewCount: drafts.filter((draft) => draft.needsReview).length,
      unreadable,
      leaseUntil: FieldValue.delete(),
      error: FieldValue.delete(),
    });
    return true;
  });
  if (!finished) return { outcome: 'abandoned', jobId };
  await removeStaleFigures(bucket, `questionFigures/${jobId}/`, figurePaths);

  await notify(deps, { trigger: PIPELINE_NOTICES.ready, jobId, attempts });
  return { outcome: 'ready', jobId, provider: providerName, questionCount: drafts.length, usage };
}

/** Runs the model on the exam (optionally focused on one question), records the billed usage, validates the answer. */
async function solve(deps, jobId, { job, exam, providerName, month, budget, focus }) {
  const provider = deps.getProvider(providerName);
  let answer;
  try {
    answer = await provider.solveExam({
      files: exam.modelFiles, kind: job.kind, pageCount: exam.pageCount, ...(focus ? { focus } : {}),
    });
  } catch (error) {
    if (error?.usage) await recordRun(deps, jobId, { month, provider: providerName, budget, usage: error.usage });
    throw error;
  }
  const usage = normalizeUsage(answer?.usage);
  await recordRun(deps, jobId, { month, provider: providerName, budget, usage });
  const { questions, unreadable } = validateModelOutput(answer?.output, { pageCount: exam.pageCount });
  return { usage, questions, unreadable };
}

/** One draft question (figures cropped and uploaded) at `order`; `paths` are the figures it references. */
async function buildDraft(deps, exam, jobId, question, order, { providerName, modelId, now }) {
  const figures = [];
  const pendingFigures = [];
  const paths = [];
  for (const [k, figure] of question.figureBoxes.entries()) {
    const index = k + 1;
    const crop = await cropFor(exam, figure, { jobId, order, index });
    if (!crop) {
      pendingFigures.push({ index, page: figure.page, box: figure.box });
      continue;
    }
    const storagePath = figureStoragePath(jobId, order, index);
    await deps.bucket.file(storagePath).save(crop.bytes, {
      resumable: false,
      contentType: 'image/jpeg',
      metadata: { cacheControl: 'private, max-age=31536000' },
    });
    paths.push(storagePath);
    figures.push({ storagePath, width: crop.width, height: crop.height });
  }
  const draft = {
    schemaVersion: QUESTION_SCHEMA_VERSION,
    order,
    label: question.label,
    text: question.text,
    speech: question.speech,
    choices: question.choices,
    figures,
    ...(pendingFigures.length > 0 ? { pendingFigures } : {}),
    answer: question.answer,
    solution: question.solution,
    topics: question.topics,
    difficulty: question.difficulty,
    hasFigure: question.hasFigure,
    confidence: question.confidence,
    needsReview: question.needsReview || pendingFigures.length > 0,
    provider: providerName,
    modelId,
    promptVersion: PROMPT_VERSION,
    generatedAt: now,
  };
  return { draft, paths };
}

/** Downloads the job's files in order and builds the model input plus a page index for cropping. */
async function loadExam(deps, job) {
  const files = (Array.isArray(job.files) ? job.files : [])
    .filter((file) => typeof file?.storagePath === 'string' && file.storagePath !== '')
    .sort((a, b) => (a.order ?? 0) - (b.order ?? 0));
  if (files.length === 0) throw new PipelineError('no-files', 'The job has no files', { retryable: false });

  const modelFiles = [];
  const pages = []; // pages[n - 1] = { image } | { pdf, pageIndex }
  for (const [position, file] of files.entries()) {
    const bytes = await download(deps.bucket, file.storagePath);
    if (/\.pdf$/i.test(file.storagePath) || isPdf(bytes)) {
      let count = deps.pdf?.pageCount ? await deps.pdf.pageCount(bytes) : pdfPageCount(bytes);
      if (!Number.isInteger(count) || count < 1) {
        // Unknown page count: allowed only for the last file, whose pages then run up to the page limit.
        if (position !== files.length - 1) {
          throw new PipelineError('pdf-page-count', `Cannot count the pages of ${file.storagePath}`, { retryable: false });
        }
        logger.warn('PDF page count unknown; page numbers are not range-checked', { storagePath: file.storagePath });
        count = Math.max(1, LIMITS.unreadablePages - pages.length);
      }
      modelFiles.push({ bytes, mimeType: 'application/pdf' });
      for (let pageIndex = 0; pageIndex < count; pageIndex += 1) pages.push({ pdf: bytes, pageIndex });
    } else {
      let image;
      try {
        image = await normalizePageImage(bytes);
      } catch (error) {
        throw new PipelineError('bad-file', `${file.storagePath} is not a readable image: ${error?.message ?? error}`, {
          retryable: false,
        });
      }
      modelFiles.push({ bytes: image.bytes, mimeType: 'image/jpeg' });
      pages.push({ image });
    }
  }
  if (pages.length > LIMITS.unreadablePages) {
    throw new PipelineError('too-many-pages', `The exam has more than ${LIMITS.unreadablePages} pages`, { retryable: false });
  }
  return { modelFiles, pages, pageCount: pages.length, renderPdfPage: deps.pdf?.renderPage };
}

async function download(bucket, storagePath) {
  try {
    const [bytes] = await bucket.file(storagePath).download();
    return bytes;
  } catch (error) {
    const missing = error?.code === 404;
    throw new PipelineError(missing ? 'missing-file' : 'download-failed', `Could not download ${storagePath}: ${error?.message ?? error}`, {
      retryable: !missing,
    });
  }
}

const isPdf = (bytes) => bytes.length >= 5 && bytes.subarray(0, 5).toString('latin1') === '%PDF-';

/** The cropped figure, or null when it cannot be cropped (PDF without rasteriser, bad box) — kept as pending. */
async function cropFor(exam, figure, where) {
  const page = exam.pages[figure.page - 1];
  if (!page) return null;
  try {
    if (!page.image && page.pdf && exam.renderPdfPage) {
      page.image = await normalizePageImage(await exam.renderPdfPage(page.pdf, page.pageIndex));
    }
    if (!page.image) return null;
    return await cropFigure(page.image, figure.box);
  } catch (error) {
    logger.warn('Could not crop a figure; kept as pending', { ...where, error: String(error) });
    return null;
  }
}

async function jobHasStatus(db, jobId, status) {
  const snapshot = await jobRef(db, jobId).get();
  return snapshot.exists && snapshot.get('status') === status;
}

/** Figures under `prefix` (an earlier run of the job, or of one question) that the new drafts no longer reference. */
async function removeStaleFigures(bucket, prefix, keep) {
  try {
    const [files] = await bucket.getFiles({ prefix });
    await Promise.all(files.filter((file) => !keep.has(file.name)).map((file) => file.delete({ ignoreNotFound: true })));
  } catch (error) {
    logger.warn('Could not remove stale figures', { prefix, error: String(error) });
  }
}

// MARK: - Single question (K8 draft, K15 published)

async function processQuestion(deps, { jobId, order, provider, target, isFinalAttempt, now }) {
  if (!Number.isInteger(order) || order < 1 || order > 999) return { outcome: 'skipped', reason: 'bad-order' };
  if (!PROVIDERS.includes(provider)) return { outcome: 'skipped', reason: 'no-provider' };
  const status = QUESTION_TARGETS[target];
  if (!status) return { outcome: 'skipped', reason: 'bad-target' };

  const claim = await claimQuestion(deps, { jobId, order, provider, status, now });
  if (claim.outcome === 'skipped') return claim;
  if (claim.outcome === 'leased') {
    if (isFinalAttempt) return { outcome: 'skipped', reason: 'leased' };
    throw new PipelineError('lease-held', `Question ${order} of job ${jobId} is being regenerated by another task`);
  }
  if (claim.outcome === 'over-cap') {
    await noticeBudget(deps, jobId, claim, now);
    return { outcome: 'skipped', reason: 'over-cap', jobId, order };
  }

  try {
    return await runQuestion(deps, jobId, { ...claim, order, target, status, providerName: provider });
  } catch (error) {
    if (error?.retryable !== false && !isFinalAttempt) {
      await releaseQuestion(deps, jobId, order, error, { failed: false });
      throw error;
    }
    logger.error('Question regeneration failed', { jobId, order, error: errorText(error) });
    await releaseQuestion(deps, jobId, order, error, { failed: true });
    return { outcome: 'failed', jobId, order, error: errorText(error) };
  }
}

async function claimQuestion(deps, { jobId, order, provider, status, now }) {
  const { db } = deps;
  return db.runTransaction(async (tx) => {
    const [jobSnapshot, draftSnapshot] = await tx.getAll(jobRef(db, jobId), draftRef(db, jobId, order));
    if (!jobSnapshot.exists) return { outcome: 'skipped', reason: 'missing' };
    const job = jobSnapshot.data();
    // A discarded job never gets drafts again; a whole-exam run (queued/processing) owns the drafts meanwhile.
    if (job.status !== status) return { outcome: 'skipped', reason: `status-${job.status}` };
    if (!draftSnapshot.exists) return { outcome: 'skipped', reason: 'missing-draft' };
    const draft = draftSnapshot.data();
    const leaseUntil = draft.regenerationLeaseUntil?.toDate?.() ?? null;
    if (leaseUntil && leaseUntil > now) return { outcome: 'leased' };

    const overCap = await checkCap(tx, deps, { job, provider, now });
    if (overCap) return { outcome: 'over-cap', ...overCap };

    const modelId = deps.getProvider(provider).modelId;
    tx.update(draftSnapshot.ref, {
      regenerationLeaseUntil: new Date(now.getTime() + LEASE_MS),
      regenerationError: FieldValue.delete(),
    });
    const init = usageInit(job);
    if (Object.keys(init).length > 0) tx.update(jobSnapshot.ref, init);
    return {
      outcome: 'claimed', job, draft, modelId, month: usageMonthKey(now), budget: jobBudget(job),
    };
  });
}

async function runQuestion(deps, jobId, { job, draft: previous, modelId, month, budget, order, target, status, providerName }) {
  const { db, bucket } = deps;
  const exam = await loadExam(deps, job);
  const label = typeof previous.label === 'string' && previous.label ? previous.label : String(order);
  const { usage, questions } = await solve(deps, jobId, {
    job, exam, providerName, month, budget, focus: { label, order },
  });
  // The model is asked for one question; if it returns more, the one with the same label is used.
  const question = questions.find((entry) => entry.label === label) ?? (questions.length === 1 ? questions[0] : null);
  if (!question) {
    throw new PipelineError('question-not-found', `The answer has no question labelled ${label} (${questions.length} returned)`);
  }

  if (!(await jobHasStatus(db, jobId, status))) return { outcome: 'abandoned', jobId, order };
  const { draft, paths } = await buildDraft(deps, exam, jobId, question, order, {
    providerName, modelId, now: clock(deps)(),
  });

  const collection = jobRef(db, jobId).collection(DRAFTS_COLLECTION);
  const finished = await db.runTransaction(async (tx) => {
    const ref = jobRef(db, jobId);
    const snapshot = await tx.get(ref);
    if (!snapshot.exists || snapshot.get('status') !== status) return false;
    const drafts = await tx.get(collection);
    const key = questionOrderKey(order);
    const needsReviewCount = drafts.docs
      .filter((doc) => (doc.id === key ? draft.needsReview : doc.get('needsReview') === true)).length;
    // `set` replaces the whole draft: the admin's earlier edit marks and the regeneration lease go with it.
    tx.set(collection.doc(key), draft);
    tx.update(ref, { needsReviewCount });
    return true;
  });
  if (!finished) return { outcome: 'abandoned', jobId, order };

  let published = null;
  if (target === 'published') {
    try {
      published = (await publishDraftQuestion(deps, { jobId, order })).questionId;
    } catch (error) {
      // The model run is paid for and the draft is rewritten; a retry would pay again, so the draft records it.
      logger.error('Could not publish a regenerated question', { jobId, order, error: String(error) });
      await draftRef(db, jobId, order).update({ regenerationError: errorText(error) }).catch(() => {});
      return { outcome: 'publish-failed', jobId, order, error: errorText(error) };
    }
  }
  await removeStaleFigures(bucket, `questionFigures/${jobId}/${questionOrderKey(order)}-`, new Set(paths));
  return { outcome: target === 'published' ? 'published' : 'ready', jobId, order, provider: providerName, usage, questionId: published };
}

/** Drops the draft's regeneration lease (a retry follows) or, after the last attempt, records the error on it. */
async function releaseQuestion(deps, jobId, order, error, { failed }) {
  try {
    await deps.db.runTransaction(async (tx) => {
      const ref = draftRef(deps.db, jobId, order);
      const snapshot = await tx.get(ref);
      if (!snapshot.exists || !snapshot.get('regenerationLeaseUntil')) return;
      tx.update(ref, {
        regenerationLeaseUntil: FieldValue.delete(),
        ...(failed ? { regenerationError: errorText(error) } : {}),
      });
    });
  } catch (releaseError) {
    logger.error('Could not release a question regeneration lease', { jobId, order, error: String(releaseError) });
  }
}

// MARK: - Usage

function normalizeUsage(usage) {
  const count = (value) => (Number.isFinite(value) && value > 0 ? Math.round(value) : 0);
  return { inputTokens: count(usage?.inputTokens), outputTokens: count(usage?.outputTokens) };
}

/** Adds one billed run to the job's `usage` and the month's totals, in one batch. */
async function recordRun(deps, jobId, { month, provider, budget, usage: raw }) {
  const { db } = deps;
  const usage = normalizeUsage(raw);
  const cost = costUsd(provider, usage);
  const batch = db.batch();
  batch.update(jobRef(db, jobId), {
    'usage.inputTokens': FieldValue.increment(usage.inputTokens),
    'usage.outputTokens': FieldValue.increment(usage.outputTokens),
    'usage.costUsd': FieldValue.increment(cost),
  });
  addUsage(batch, db, { month, provider, budget, usage, cost, now: clock(deps)() });
  await batch.commit();
}

// MARK: - Failure

function errorText(error) {
  const code = error?.code ? `${error.code}: ` : '';
  return `${code}${error?.message ?? String(error)}`.slice(0, ERROR_LIMIT);
}

async function releaseForRetry(deps, jobId, error) {
  logger.warn('Conversion attempt failed; the task will be retried', { jobId, error: errorText(error) });
  try {
    await deps.db.runTransaction(async (tx) => {
      const ref = jobRef(deps.db, jobId);
      const snapshot = await tx.get(ref);
      if (!snapshot.exists || snapshot.get('status') !== 'processing') return;
      tx.update(ref, { error: errorText(error), leaseUntil: FieldValue.delete() });
    });
  } catch (releaseError) {
    logger.error('Could not release a conversion lease', { jobId, error: String(releaseError) });
  }
}

async function failJob(deps, jobId, error) {
  const message = errorText(error);
  logger.error('Conversion failed', { jobId, error: message });
  const failedAt = clock(deps)();
  const result = await deps.db.runTransaction(async (tx) => {
    const ref = jobRef(deps.db, jobId);
    const snapshot = await tx.get(ref);
    if (!snapshot.exists || !['queued', 'processing'].includes(snapshot.get('status'))) return null;
    tx.update(ref, { status: 'failed', error: message, failedAt, leaseUntil: FieldValue.delete() });
    return { attempts: snapshot.get('attempts') ?? 0 };
  });
  if (!result) return { outcome: 'abandoned', jobId };
  await notify(deps, { trigger: PIPELINE_NOTICES.failed, jobId, attempts: result.attempts });
  return { outcome: 'failed', jobId, error: message };
}

// MARK: - Helpers

const clock = (deps) => deps.now ?? (() => new Date());

const isMap = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);

/** Admin notices never fail the job: the draft (or the failure) is already recorded. */
async function notify(deps, notice) {
  if (!deps.notifyAdmins) return;
  try {
    await deps.notifyAdmins(notice);
  } catch (error) {
    logger.error('Could not notify the admins', { ...notice, error: String(error) });
  }
}

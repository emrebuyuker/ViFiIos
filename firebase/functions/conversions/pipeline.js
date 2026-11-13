// The AI conversion pipeline (4.2.0 Faz 1A): one exam's files → the admin-picked model on Vertex AI → validated draft
// questions with cropped figures under `examConversions/{jobId}/questions/{nnn}` → `ready` (+ an admin notice).
//
// `processExamConversionHandler` is the body of a Cloud Tasks queue function. `index.js` wires it (Faz 1B / merge):
//
//   export const processExamConversion = onTaskDispatched(TASK_QUEUE_OPTIONS, (request) =>
//     processExamConversionHandler(liveDeps, { jobId: request.data?.jobId, retryCount: request.retryCount }));
//
// Flow per task: claim the job in one transaction (only `queued` / `processing` with `model.provider`; the monthly
// cap of usage.js checked against `aiUsage/{YYYY-MM}`; status → `processing`, `attempts` + 1, a lease) → download the
// files → `provider.solveExam` → record the run's usage and cost (job + month, even when the answer is then rejected)
// → `validateModelOutput` → crop figures into `questionFigures/{jobId}/{nnn}-{k}.jpg` → write the drafts (stale ones
// from an earlier run removed) → `ready` + `readyAt` → `deps.notifyAdmins({ trigger: conversionReady, … })`.
//
// Failures: a retryable error (model/network/invalid output) is re-thrown so Cloud Tasks retries the task; on the last
// attempt, or for a permanent error (missing files, unknown file type), the job becomes `failed` with `error` and the
// admins get `conversionFailed`. A job over the monthly cap stays `queued` (one admin notice per month) and, when
// `deps.enqueue` is wired, is re-enqueued for the start of next month. A re-delivered task for a job that is already
// `ready` / `failed` / `published` / `discarded` does nothing.
//
// Dependencies (`deps`): `db` (Firestore `vifi`), `bucket` (Storage), `getProvider(name)` (providers/index.js
// `liveProviders()`, a fake in tests), `notifyAdmins({ trigger, jobId, attempts, … })` (Faz 1B, automatic.js),
// optional `now()`, `enqueue(data, { scheduleTime })`, `pdf: { pageCount(bytes), renderPage(bytes, pageIndex) }`
// (a PDF rasteriser — none is bundled yet, see images.js), `maxAttempts`, `capUsd`.

import { FieldValue } from 'firebase-admin/firestore';
import * as logger from 'firebase-functions/logger';
import { TRIGGERS } from '../notifications/automatic.js';
import { PROMPT_VERSION } from './prompt.js';
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

/** Cloud Tasks can schedule at most 30 days ahead; a budget deferral re-checks at least this often. */
const MAX_SCHEDULE_AHEAD_MS = 29 * 24 * 60 * 60 * 1000;
const ERROR_LIMIT = 500;
const BATCH_LIMIT = 400;

/**
 * The `trigger` passed to `deps.notifyAdmins`. `budgetExceeded` is NOT yet in automatic.js `TRIGGERS` (track 1B owns
 * that file): 1B adds it or maps it onto an existing admin notice.
 */
export const PIPELINE_NOTICES = Object.freeze({
  ready: TRIGGERS.conversionReady,
  failed: TRIGGERS.conversionFailed,
  budgetExceeded: 'conversionBudgetExceeded',
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

export async function processExamConversionHandler(deps, { jobId, retryCount = 0 } = {}) {
  const now = clock(deps)();
  if (!JOB_ID_PATTERN.test(jobId ?? '')) return { outcome: 'skipped', reason: 'bad-job-id' };
  const maxAttempts = deps.maxAttempts ?? TASK_QUEUE_OPTIONS.retryConfig.maxAttempts;
  const isFinalAttempt = (Number(retryCount) || 0) + 1 >= maxAttempts;

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

async function claimJob(deps, jobId, now) {
  const { db } = deps;
  const capUsd = deps.capUsd ?? MONTHLY_CAP_USD;
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
    if (budget === 'monthly') {
      const usage = await tx.get(usageRef(db, month));
      const spent = spentUsd(usage);
      const estimate = estimateJobCostUsd({ provider, pageCount: Array.isArray(job.files) ? job.files.length : 1 });
      if (isOverCap({ spentUsd: spent, estimateUsd: estimate, capUsd })) {
        const deferredUntil = nextMonthStart(now);
        tx.update(ref, {
          status: 'queued', budgetDeferredMonth: month, deferredUntil, leaseUntil: FieldValue.delete(),
        });
        return { outcome: 'deferred', jobId, month, spentUsd: spent, capUsd, deferredUntil, attempts: job.attempts ?? 0 };
      }
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
    });
    return { outcome: 'claimed', job, provider, modelId, month, budget, attempts: (job.attempts ?? 0) + 1 };
  });
}

async function deferForBudget(deps, jobId, claim, now) {
  try {
    if (await claimCapNotice(deps.db, claim.month, now)) {
      await notify(deps, {
        trigger: PIPELINE_NOTICES.budgetExceeded, jobId, attempts: claim.attempts,
        month: claim.month, spentUsd: claim.spentUsd, capUsd: claim.capUsd,
      });
    }
  } catch (error) {
    logger.error('Could not send the AI budget notice', { jobId, month: claim.month, error: String(error) });
  }
  if (!deps.enqueue) return;
  const scheduleTime = new Date(Math.min(claim.deferredUntil.getTime(), now.getTime() + MAX_SCHEDULE_AHEAD_MS));
  try {
    await deps.enqueue({ jobId }, { scheduleTime });
  } catch (error) {
    // The job stays `queued`; an admin restart (or a later enqueue) picks it up.
    logger.error('Could not re-enqueue a budget-deferred conversion', { jobId, error: String(error) });
  }
}

// MARK: - Run

async function runConversion(deps, jobId, claim) {
  const { db, bucket } = deps;
  const { job, provider: providerName, modelId, month, budget, attempts } = claim;
  const provider = deps.getProvider(providerName);
  const exam = await loadExam(deps, job);

  let answer;
  try {
    answer = await provider.solveExam({ files: exam.modelFiles, kind: job.kind, pageCount: exam.pageCount });
  } catch (error) {
    if (error?.usage) await recordRun(deps, jobId, { month, provider: providerName, budget, usage: error.usage });
    throw error;
  }
  const usage = normalizeUsage(answer?.usage);
  await recordRun(deps, jobId, { month, provider: providerName, budget, usage });

  const { questions, unreadable } = validateModelOutput(answer?.output, { pageCount: exam.pageCount });
  const now = clock(deps)();
  const drafts = [];
  const figurePaths = new Set();
  for (const question of questions) {
    const figures = [];
    const pendingFigures = [];
    for (const [k, figure] of question.figureBoxes.entries()) {
      const index = k + 1;
      const crop = await cropFor(exam, figure, { jobId, order: question.order, index });
      if (!crop) {
        pendingFigures.push({ index, page: figure.page, box: figure.box });
        continue;
      }
      const storagePath = figureStoragePath(jobId, question.order, index);
      await bucket.file(storagePath).save(crop.bytes, {
        resumable: false,
        contentType: 'image/jpeg',
        metadata: { cacheControl: 'private, max-age=31536000' },
      });
      figurePaths.add(storagePath);
      figures.push({ storagePath, width: crop.width, height: crop.height });
    }
    drafts.push({
      schemaVersion: QUESTION_SCHEMA_VERSION,
      order: question.order,
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
    });
  }

  await writeDrafts(db, jobId, drafts);
  await removeStaleFigures(bucket, jobId, figurePaths);

  const readyAt = clock(deps)();
  const finished = await db.runTransaction(async (tx) => {
    const ref = jobRef(db, jobId);
    const snapshot = await tx.get(ref);
    // An admin discarded (or restarted) the job meanwhile: leave its new state alone.
    if (!snapshot.exists || snapshot.get('status') !== 'processing') return false;
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

  await notify(deps, { trigger: PIPELINE_NOTICES.ready, jobId, attempts });
  return { outcome: 'ready', jobId, provider: providerName, questionCount: drafts.length, usage };
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

async function writeDrafts(db, jobId, drafts) {
  const collection = jobRef(db, jobId).collection(DRAFTS_COLLECTION);
  const keep = new Set(drafts.map((draft) => questionOrderKey(draft.order)));
  const stale = (await collection.listDocuments()).filter((ref) => !keep.has(ref.id));
  const operations = [
    ...drafts.map((draft) => (batch) => batch.set(collection.doc(questionOrderKey(draft.order)), draft)),
    ...stale.map((ref) => (batch) => batch.delete(ref)),
  ];
  for (let start = 0; start < operations.length; start += BATCH_LIMIT) {
    const batch = db.batch();
    operations.slice(start, start + BATCH_LIMIT).forEach((apply) => apply(batch));
    await batch.commit();
  }
}

/** Figures of an earlier run of this job that the new drafts no longer reference. */
async function removeStaleFigures(bucket, jobId, keep) {
  try {
    const [files] = await bucket.getFiles({ prefix: `questionFigures/${jobId}/` });
    await Promise.all(files.filter((file) => !keep.has(file.name)).map((file) => file.delete({ ignoreNotFound: true })));
  } catch (error) {
    logger.warn('Could not remove stale figures', { jobId, error: String(error) });
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

/** Admin notices never fail the job: the draft (or the failure) is already recorded. */
async function notify(deps, notice) {
  if (!deps.notifyAdmins) return;
  try {
    await deps.notifyAdmins(notice);
  } catch (error) {
    logger.error('Could not notify the admins', { ...notice, error: String(error) });
  }
}

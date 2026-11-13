#!/usr/bin/env node
// One-time conversion of the legacy archive into structured exams (4.2.0, owner decisions K12c + K24).
//
// Finds the published exams that are not structured yet and starts their AI conversion job `exam-<examId>` with the
// chosen model — exactly what the admin's "Yeni yapıya geçir" / bulk queue do (functions/conversions/jobs.js
// `startLegacyRun`), except that the jobs carry `budget: 'oneTime'`: their runs are summed apart and never wait on
// the $50 monthly cap (functions/conversions/usage.js). Every draft still goes through the admin's review one by one;
// nothing is published by this script.
//
// Usage (run from firebase/, with the functions' dependencies installed: `npm --prefix functions ci`):
//
//   node scripts/convert-legacy-exams.mjs --provider claude|gemini [--course <id> | --department <id>] [--limit N]
//        [--project <id>] [--database vifi] [--dry-run | --apply] [--confirm-project <id>]
//
//   --provider         required, no default (K9).
//   --course / --department  one scope (catalog node ids, e.g. `ege-universitesi__…__algoritmalar`); neither = all.
//   --limit N          at most N exams (in exam-id order), e.g. a 10-exam pilot first.
//   --dry-run          the default: prints the exam count, the estimated pages and the estimated cost; writes nothing.
//   --apply            creates the jobs (`budget: 'oneTime'`) and hands them to the task queue `processExamConversion`.
//   --project / --database   the target (database default `vifi`, the named database of the archive).
//   --confirm-project  must repeat the project id for any run that is not against the local emulator.
//
// Safety:
// - Local = FIRESTORE_EMULATOR_HOST points to this machine. Anything else is PRODUCTION and is refused unless
//   `--project` is given and `--confirm-project` repeats it exactly; `--apply` there writes live data and spends
//   real money on Vertex AI — run it ONLY with the owner's explicit approval, after a dry run of the same scope.
//   (A production dry run only reads; it is allowed with the same confirmation so the cost can be seen first.)
// - Idempotent: exams already structured, exams with any job that is queued / processing / ready (their own
//   `exam-<id>` or a duplicate submission's `sub-<id>`), and exams whose job failed, was discarded or is published
//   are skipped. Only exams without a job, or whose job is waiting for a model (a 4.1.0 approval) or for a failed
//   enqueue, are started. Re-running after a partial run starts only what is left.
// - Locally (emulator) nothing is enqueued unless CLOUD_TASKS_EMULATOR_HOST is set: the jobs are created and stay
//   `queued`, which is enough for a rehearsal.
// - In production the jobs are enqueued with the owner's Application Default Credentials (`gcloud auth
//   application-default login` as a project owner); the queue exists only after `processExamConversion` is deployed.
//
// Exit codes: 0 success, 1 at least one exam could not be started, 2 usage error or refused.

import { createRequire } from 'node:module';
import { realpathSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

// The Admin SDK must be the functions' copy: the job helpers write its `FieldValue`s.
const requireFromFunctions = createRequire(new URL('../functions/package.json', import.meta.url));

export const EXIT_OK = 0;
export const EXIT_FAILURES = 1;
export const EXIT_REFUSED = 2;

export const PROVIDERS = Object.freeze(['claude', 'gemini']);
export const DEFAULT_DATABASE = 'vifi';
export const PRODUCTION_PROJECT = 'vifi-831a8';
export const REQUESTED_BY = 'script:convert-legacy-exams';
/** The pipeline's Cloud Tasks queue (functions/index.js `CONVERSION_QUEUE`). */
export const CONVERSION_QUEUE = 'locations/europe-west1/functions/processExamConversion';

const ID_PATTERN = /^[A-Za-z0-9_-]{1,700}$/;
const ACTIVE_STATUSES = Object.freeze(['queued', 'processing', 'ready']);
const PAGE_SIZE = 500;
const GET_ALL_CHUNK = 100;

export const USAGE = `Usage:
  convert-legacy-exams.mjs --provider claude|gemini [--course <id> | --department <id>] [--limit <n>]
                           [--project <id>] [--database <id>] [--dry-run | --apply] [--confirm-project <id>]

Without --apply nothing is written (dry run: exam count, page and cost estimate).
Outside the local emulator --project and a matching --confirm-project are required; --apply there needs the owner's approval.`;

/** Wrong command-line usage. */
export class UsageError extends Error {}

/** The script will not run against this target. */
export class RefusalError extends Error {}

// MARK: - Command line

/**
 * Parses `argv` (without the node binary and script path).
 * @returns {{ help?: true, provider: string, scope: { field: string, id: string }|null, limit: number|null,
 *   project: string|null, database: string, apply: boolean, confirmProject: string|null }}
 */
export function parseCommandLine(argv) {
  let parsed;
  try {
    parsed = parseArgs({
      args: argv,
      strict: true,
      options: {
        provider: { type: 'string' },
        course: { type: 'string' },
        department: { type: 'string' },
        limit: { type: 'string' },
        project: { type: 'string' },
        database: { type: 'string' },
        'dry-run': { type: 'boolean', default: false },
        apply: { type: 'boolean', default: false },
        'confirm-project': { type: 'string' },
        help: { type: 'boolean', short: 'h', default: false },
      },
    });
  } catch (error) {
    throw new UsageError(error.message);
  }
  const { values } = parsed;
  if (values.help) return { help: true };

  if (!PROVIDERS.includes(values.provider)) throw new UsageError('--provider claude|gemini is required (there is no default).');
  if (values.apply && values['dry-run']) throw new UsageError('--apply and --dry-run exclude each other.');
  if (values.course !== undefined && values.department !== undefined) {
    throw new UsageError('Give at most one scope: --course or --department.');
  }
  let scope = null;
  if (values.course !== undefined) scope = { field: 'courseId', id: values.course };
  if (values.department !== undefined) scope = { field: 'departmentId', id: values.department };
  if (scope && !ID_PATTERN.test(scope.id)) throw new UsageError(`Invalid ${scope.field}: ${scope.id}`);

  let limit = null;
  if (values.limit !== undefined) {
    limit = Number(values.limit);
    if (!Number.isInteger(limit) || limit < 1) throw new UsageError('--limit must be a positive integer.');
  }
  const database = values.database ?? DEFAULT_DATABASE;
  if (!/^[a-z0-9-]{1,63}$|^\(default\)$/.test(database)) throw new UsageError(`Invalid database id: ${database}`);
  const project = values.project ?? null;
  if (project !== null && !/^[a-z][a-z0-9-]{4,61}[a-z0-9]$/.test(project)) throw new UsageError(`Invalid project id: ${project}`);

  return {
    provider: values.provider,
    scope,
    limit,
    project,
    database,
    apply: values.apply,
    confirmProject: values['confirm-project'] ?? null,
  };
}

/** True when `host` (`FIRESTORE_EMULATOR_HOST`) is an emulator on this machine. */
export function isLocalHost(host) {
  return typeof host === 'string' && /^(127\.0\.0\.1|localhost|\[::1\]|::1):\d+$/.test(host);
}

/**
 * The target: `{ local, projectId }`. Local runs default to `demo-vifi`; anything else needs `--project` repeated by
 * `--confirm-project` (else `RefusalError`).
 */
export function resolveTarget(options, env = process.env) {
  const emulatorHost = env.FIRESTORE_EMULATOR_HOST;
  if (emulatorHost !== undefined && emulatorHost !== '' && !isLocalHost(emulatorHost)) {
    throw new RefusalError(`FIRESTORE_EMULATOR_HOST must point to this machine (got ${JSON.stringify(emulatorHost)}).`);
  }
  if (isLocalHost(emulatorHost)) return { local: true, projectId: options.project ?? 'demo-vifi' };
  if (!options.project) throw new RefusalError('Not on the local emulator: --project is required.');
  if (options.confirmProject !== options.project) {
    throw new RefusalError(`Not on the local emulator: repeat the project with --confirm-project ${options.project}.`);
  }
  return { local: false, projectId: options.project };
}

// MARK: - Plan

/**
 * Reads the candidates: published, not structured, convertible exams of the scope with no blocking job, in exam-id
 * order, cut to `limit`. Pure reads.
 *
 * @returns {Promise<{ scanned: number, candidates: Array<{ id: string, data: object, pages: number, costUsd: number }>,
 *   skipped: Record<string, number>, pages: number, estimatedCostUsd: number }>}
 */
export async function planConversion(db, { provider, scope, limit }) {
  const { legacyJob } = await import('../functions/conversions/jobs.js');
  const { estimatedPages } = await import('../functions/conversions/admin.js');
  const { estimateJobCostUsd } = await import('../functions/conversions/usage.js');

  const exams = await readExams(db, scope);
  const busy = await examsWithActiveJobs(db);
  const skipped = { notPublished: 0, structured: 0, notConvertible: 0, activeJob: 0, finishedJob: 0 };
  const open = [];
  for (const doc of exams) {
    const exam = doc.data();
    if (exam.status !== 'published') skipped.notPublished += 1;
    else if (exam.format === 'structured') skipped.structured += 1;
    else if (legacyJob(doc.id, exam) === null) skipped.notConvertible += 1;
    else if (busy.has(doc.id)) skipped.activeJob += 1;
    else open.push(doc);
  }

  // The exam's own job: none or waiting (a 4.1.0 approval, a failed enqueue) is started; failed / discarded /
  // published are left to the admin screens; an active one was counted above.
  const { isIdle } = await import('../functions/conversions/jobs.js');
  const candidates = [];
  for (let start = 0; start < open.length; start += GET_ALL_CHUNK) {
    const chunk = open.slice(start, start + GET_ALL_CHUNK);
    const jobs = await db.getAll(...chunk.map((doc) => db.collection('examConversions').doc(`exam-${doc.id}`)));
    chunk.forEach((doc, index) => {
      const job = jobs[index].exists ? jobs[index].data() : null;
      if (job && !isIdle(job)) {
        skipped[ACTIVE_STATUSES.includes(job.status) ? 'activeJob' : 'finishedJob'] += 1;
        return;
      }
      candidates.push(doc);
    });
  }

  const limited = limit ? candidates.slice(0, limit) : candidates;
  const planned = limited.map((doc) => {
    const pages = Math.max(1, estimatedPages(doc.data()));
    return { id: doc.id, data: doc.data(), pages, costUsd: estimateJobCostUsd({ provider, pageCount: pages }) };
  });
  return {
    scanned: exams.length,
    candidates: planned,
    notTaken: candidates.length - limited.length,
    skipped,
    pages: planned.reduce((sum, exam) => sum + exam.pages, 0),
    estimatedCostUsd: Math.round(planned.reduce((sum, exam) => sum + exam.costUsd, 0) * 100) / 100,
  };
}

/** The scope's exams (all exams without a scope, paged by document id), sorted by id. */
async function readExams(db, scope) {
  const exams = db.collection('exams');
  if (scope) {
    const snapshot = await exams.where(scope.field, '==', scope.id).get();
    return [...snapshot.docs].sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  }
  const { FieldPath } = requireFromFunctions('firebase-admin/firestore');
  const all = [];
  let last = null;
  for (;;) {
    let query = exams.orderBy(FieldPath.documentId()).limit(PAGE_SIZE);
    if (last) query = query.startAfter(last);
    const page = await query.get();
    all.push(...page.docs);
    if (page.size < PAGE_SIZE) return all;
    last = page.docs[page.size - 1];
  }
}

/** Exam ids with a queued / processing / ready job of any source (a duplicate's `sub-` job included). */
async function examsWithActiveJobs(db) {
  const snapshot = await db.collection('examConversions').where('status', 'in', [...ACTIVE_STATUSES]).get();
  const ids = new Set();
  for (const doc of snapshot.docs) {
    const examId = doc.get('placement.examId') ?? doc.get('source.examId');
    // A job waiting for a model (or a failed enqueue) does not block: starting it is exactly what is wanted.
    if (typeof examId === 'string' && doc.id === `exam-${examId}`) continue;
    if (typeof examId === 'string') ids.add(examId);
  }
  return ids;
}

// MARK: - Apply

/**
 * Starts the planned jobs one by one (`startLegacyRun`, policy `bulk`, `budget: 'oneTime'`). A job that started
 * meanwhile is skipped by the policy; a failed enqueue leaves the job `queued` with an `enqueue:` error, which a
 * re-run picks up again.
 *
 * @returns {Promise<{ started: string[], skipped: string[], failed: Array<{ id: string, error: string }> }>}
 */
export async function applyConversion(deps, plan, { provider, log = consoleLog }) {
  const { RUN_POLICIES, startLegacyRun } = await import('../functions/conversions/jobs.js');
  const started = [];
  const skipped = [];
  const failed = [];
  for (const exam of plan.candidates) {
    try {
      const result = await startLegacyRun(deps, exam.id, exam.data, {
        provider, requestedBy: REQUESTED_BY, policy: RUN_POLICIES.bulk, budget: 'oneTime',
      });
      (result.started ? started : skipped).push(result.jobId);
    } catch (error) {
      failed.push({ id: exam.id, error: error?.message ?? String(error) });
    }
    const done = started.length + skipped.length + failed.length;
    if (done % 25 === 0) log.info(`… ${done}/${plan.candidates.length}`);
  }
  return { started, skipped, failed };
}

// MARK: - CLI

const consoleLog = {
  info: (message) => process.stdout.write(`${message}\n`),
  error: (message) => process.stderr.write(`${message}\n`),
};

async function defaultDatabase(target, database) {
  const { initializeApp, applicationDefault } = requireFromFunctions('firebase-admin/app');
  const { getFirestore } = requireFromFunctions('firebase-admin/firestore');
  const app = initializeApp(target.local
    ? { projectId: target.projectId }
    : { credential: applicationDefault(), projectId: target.projectId }, 'convert-legacy-exams');
  return { app, db: getFirestore(app, database) };
}

/** The live task-queue enqueue (production, or a Cloud Tasks emulator); locally without one, a logging no-op. */
function defaultEnqueue(target, app, log) {
  if (target.local && !process.env.CLOUD_TASKS_EMULATOR_HOST) {
    return async (jobId) => log.info(`(local) would enqueue ${jobId}`);
  }
  const { getFunctions } = requireFromFunctions('firebase-admin/functions');
  const queue = getFunctions(app).taskQueue(CONVERSION_QUEUE);
  return (jobId, options = {}) => queue.enqueue({ jobId, ...options });
}

/**
 * Runs the CLI and resolves to its exit code.
 * @param {string[]} argv Arguments after the script path.
 * @param {{ db?: object, enqueueConversion?: Function, env?: object, log?: typeof consoleLog }} [dependencies]
 *   Tests inject the emulator `db` and a fake queue.
 */
export async function run(argv, { db: injectedDb, enqueueConversion, env = process.env, log = consoleLog } = {}) {
  let options;
  let target;
  try {
    options = parseCommandLine(argv);
    if (options.help) {
      log.info(USAGE);
      return EXIT_OK;
    }
    target = resolveTarget(options, env);
  } catch (error) {
    if (error instanceof UsageError) {
      log.error(`${error.message}\n\n${USAGE}`);
      return EXIT_REFUSED;
    }
    if (error instanceof RefusalError) {
      log.error(`Refused: ${error.message}`);
      return EXIT_REFUSED;
    }
    throw error;
  }

  const where = target.local ? `EMULATOR ${env.FIRESTORE_EMULATOR_HOST}` : 'PRODUCTION';
  const scope = options.scope ? `${options.scope.field} == ${options.scope.id}` : 'all exams';
  log.info(`${options.apply ? 'APPLY' : 'dry run'} · ${where} · project ${target.projectId} · database ${options.database}`);
  log.info(`provider ${options.provider} · ${scope}${options.limit ? ` · limit ${options.limit}` : ''}`);

  let app = null;
  try {
    const db = injectedDb ?? ({ app } = await defaultDatabase(target, options.database)).db;
    const plan = await planConversion(db, options);
    log.info(`Scanned ${plan.scanned} exams; skipped: ${JSON.stringify(plan.skipped)}`);
    log.info(`To convert: ${plan.candidates.length} exams${plan.notTaken ? ` (+${plan.notTaken} over the limit)` : ''}, `
      + `~${plan.pages} pages, estimated cost ~$${plan.estimatedCostUsd.toFixed(2)} (${options.provider}, list prices, one-time budget)`);
    if (!options.apply) {
      log.info('Dry run: nothing written. Re-run with --apply (owner approval) to start the jobs.');
      return EXIT_OK;
    }
    if (plan.candidates.length === 0) {
      log.info('Nothing to start.');
      return EXIT_OK;
    }
    const deps = { db, enqueueConversion: enqueueConversion ?? defaultEnqueue(target, app, log) };
    const result = await applyConversion(deps, plan, { provider: options.provider, log });
    log.info(`Started ${result.started.length}, already started ${result.skipped.length}, failed ${result.failed.length}.`);
    for (const failure of result.failed) log.error(`  ${failure.id}: ${failure.error}`);
    return result.failed.length > 0 ? EXIT_FAILURES : EXIT_OK;
  } catch (error) {
    log.error(`Error: ${error?.message ?? error}`);
    return EXIT_FAILURES;
  } finally {
    if (app) {
      const { deleteApp } = requireFromFunctions('firebase-admin/app');
      await deleteApp(app).catch(() => {});
    }
  }
}

/** True when this file is the script node was started with (not when imported by the tests). */
function isEntryPoint() {
  if (!process.argv[1]) return false;
  try {
    // realpath + NFC: symlinks and macOS decomposed (NFD) Unicode paths must still compare equal.
    const invoked = realpathSync(resolve(process.argv[1])).normalize('NFC');
    return realpathSync(fileURLToPath(import.meta.url)).normalize('NFC') === invoked;
  } catch {
    return false;
  }
}

if (isEntryPoint()) {
  process.exitCode = await run(process.argv.slice(2));
}

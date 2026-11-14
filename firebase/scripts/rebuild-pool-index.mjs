#!/usr/bin/env node
// One-time (re)build of the practice-mode pool index `questionPoolIndex/<subjectId>` (4.2.0 "Sınava gir"; contract:
// functions/conversions/schema.js PRACTICE MODE, shape: functions/conversions/poolIndex.js) from the existing
// `questionPools` documents — for pools published before the index existed. From then on publish.js keeps the index
// in the pools' own transactions, so this is needed once (or to repair a drifted index).
//
// Usage (run from firebase/, with the functions' dependencies installed: `npm --prefix functions ci`):
//
//   node scripts/rebuild-pool-index.mjs [--project <id>] [--database vifi] [--dry-run | --apply] [--confirm-project <id>]
//
//   --dry-run          the default: prints how many index documents would be created / updated / deleted; writes nothing.
//   --apply            writes them: every subject with pools gets its full index (counts = the ids of all `__pN`
//                      parts of each pool), an index whose subject has no pool left is deleted.
//   --project / --database   the target (database default `vifi`).
//   --confirm-project  must repeat the project id for any run that is not against the local emulator.
//
// Safety:
// - Local = FIRESTORE_EMULATOR_HOST points to this machine. Anything else is PRODUCTION and is refused unless
//   `--project` is given and `--confirm-project` repeats it exactly; `--apply` there writes live data — run it ONLY
//   with the owner's explicit approval, after a dry run, and while no admin is publishing (a publish between this
//   script's read and write would be overwritten with the older count; re-running the script repairs it).
// - Idempotent: unchanged index documents are not rewritten.
//
// Exit codes: 0 success, 1 failure, 2 usage error or refused.

import { createRequire } from 'node:module';
import { realpathSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';
import {
  POOL_INDEX_COLLECTION,
  applyPoolCounts,
  hasPracticeQuestions,
  poolIndexDocument,
  poolScopeKey,
} from '../functions/conversions/poolIndex.js';

const requireFromFunctions = createRequire(new URL('../functions/package.json', import.meta.url));

export const EXIT_OK = 0;
export const EXIT_FAILURES = 1;
export const EXIT_REFUSED = 2;
export const DEFAULT_DATABASE = 'vifi';

const PAGE_SIZE = 300;
const GET_ALL_CHUNK = 100;
/** `<subjectId>__<examType>__<scopeKey>[__pN]` — the fallback when a pool document lacks its own fields. */
const POOL_ID_PATTERN = /^([A-Za-z0-9_-]+?)__([a-z-]+)__(tr|u-[A-Za-z0-9_-]+?|c-[A-Za-z0-9_-]+?)(?:__p(\d+))?$/;

export const USAGE = `Usage:
  rebuild-pool-index.mjs [--project <id>] [--database <id>] [--dry-run | --apply] [--confirm-project <id>]

Without --apply nothing is written (dry run). Outside the local emulator --project and a matching --confirm-project
are required; --apply there needs the owner's approval.`;

export class UsageError extends Error {}
export class RefusalError extends Error {}

// MARK: - Command line

export function parseCommandLine(argv) {
  let parsed;
  try {
    parsed = parseArgs({
      args: argv,
      strict: true,
      options: {
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
  if (values.apply && values['dry-run']) throw new UsageError('--apply and --dry-run exclude each other.');
  const database = values.database ?? DEFAULT_DATABASE;
  if (!/^[a-z0-9-]{1,63}$|^\(default\)$/.test(database)) throw new UsageError(`Invalid database id: ${database}`);
  const project = values.project ?? null;
  if (project !== null && !/^[a-z][a-z0-9-]{4,61}[a-z0-9]$/.test(project)) throw new UsageError(`Invalid project id: ${project}`);
  return { project, database, apply: values.apply, confirmProject: values['confirm-project'] ?? null };
}

export function isLocalHost(host) {
  return typeof host === 'string' && /^(127\.0\.0\.1|localhost|\[::1\]|::1):\d+$/.test(host);
}

/** `{ local, projectId }`; production needs `--project` repeated by `--confirm-project` (else `RefusalError`). */
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

/** The pool spec of a `questionPools` document: its own fields, else parsed from its id; `null` when unusable. */
export function poolSpecOf(id, data) {
  if (data?.subjectId && data?.examType && data?.scope) {
    return {
      subjectId: data.subjectId, examType: data.examType, scope: data.scope,
      ...(data.universityId ? { universityId: data.universityId } : {}),
      ...(data.courseId ? { courseId: data.courseId } : {}),
    };
  }
  const match = POOL_ID_PATTERN.exec(id);
  if (!match) return null;
  const [, subjectId, examType, scopeKey] = match;
  if (scopeKey === 'tr') return { subjectId, examType, scope: 'tr' };
  if (scopeKey.startsWith('u-')) return { subjectId, examType, scope: 'university', universityId: scopeKey.slice(2) };
  return { subjectId, examType, scope: 'course', courseId: scopeKey.slice(2) };
}

/**
 * Reads every pool, index and subject and works out the target index documents. Pure reads.
 *
 * @returns {Promise<{ pools: number, skippedPools: number, writes: Array<{ subjectId: string, document: object,
 *   create: boolean }>, deletes: string[], unchanged: number }>}
 */
export async function planRebuild(db) {
  const { FieldPath } = requireFromFunctions('firebase-admin/firestore');
  const counts = new Map(); // subjectId → Map(`${examType}|${scopeKey}` → count)
  let pools = 0;
  let skippedPools = 0;
  let last = null;
  for (;;) {
    let query = db.collection('questionPools').orderBy(FieldPath.documentId()).limit(PAGE_SIZE);
    if (last) query = query.startAfter(last);
    const page = await query.get();
    for (const doc of page.docs) {
      pools += 1;
      const spec = poolSpecOf(doc.id, doc.data());
      const scopeKey = spec ? poolScopeKey(spec) : null;
      if (!spec || !scopeKey) {
        skippedPools += 1;
        continue;
      }
      const ids = doc.get('ids');
      const key = `${spec.examType}|${scopeKey}`;
      if (!counts.has(spec.subjectId)) counts.set(spec.subjectId, new Map());
      const bySubject = counts.get(spec.subjectId);
      bySubject.set(key, (bySubject.get(key) ?? 0) + (Array.isArray(ids) ? ids.length : 0));
    }
    if (page.size < PAGE_SIZE) break;
    last = page.docs[page.size - 1];
  }

  const existing = new Map((await db.collection(POOL_INDEX_COLLECTION).get()).docs.map((doc) => [doc.id, doc.data()]));
  const subjectIds = [...counts.keys()];
  const names = new Map();
  for (let start = 0; start < subjectIds.length; start += GET_ALL_CHUNK) {
    const chunk = subjectIds.slice(start, start + GET_ALL_CHUNK);
    const snapshots = await db.getAll(...chunk.map((id) => db.collection('subjects').doc(id)));
    snapshots.forEach((snapshot, index) => {
      if (snapshot.exists && typeof snapshot.get('name') === 'string') names.set(chunk[index], snapshot.get('name'));
    });
  }

  const targets = new Map();
  for (const [subjectId, bySubject] of counts) {
    const types = applyPoolCounts({}, [...bySubject].map(([key, count]) => {
      const [examType, scopeKey] = key.split('|');
      return { examType, scopeKey, count };
    }));
    if (hasPracticeQuestions(types)) targets.set(subjectId, types);
  }

  const writes = [];
  let unchanged = 0;
  for (const [subjectId, types] of targets) {
    const current = existing.get(subjectId);
    const name = names.get(subjectId) ?? current?.name ?? subjectId;
    if (current && current.name === name && current.subjectId === subjectId && sameJson(current.types, types)) {
      unchanged += 1;
      continue;
    }
    writes.push({ subjectId, create: !current, document: poolIndexDocument({ subjectId, name, types, updatedAt: null }) });
  }
  const deletes = [...existing.keys()].filter((subjectId) => !targets.has(subjectId));
  return { pools, skippedPools, writes, deletes, unchanged };
}

function sameJson(a, b) {
  const sorted = (value) => (value && typeof value === 'object'
    ? Object.fromEntries(Object.keys(value).sort().map((key) => [key, sorted(value[key])]))
    : value);
  return JSON.stringify(sorted(a)) === JSON.stringify(sorted(b));
}

// MARK: - Apply

export async function applyRebuild(db, plan, now = new Date()) {
  const { Timestamp } = requireFromFunctions('firebase-admin/firestore');
  const updatedAt = Timestamp.fromDate(now);
  const writer = db.bulkWriter();
  const results = [
    ...plan.writes.map(({ subjectId, document }) => writer
      .set(db.collection(POOL_INDEX_COLLECTION).doc(subjectId), { ...document, updatedAt })
      .then(() => null, (error) => error)),
    ...plan.deletes.map((subjectId) => writer
      .delete(db.collection(POOL_INDEX_COLLECTION).doc(subjectId))
      .then(() => null, (error) => error)),
  ];
  await writer.close();
  const failures = (await Promise.all(results)).filter(Boolean);
  return { written: plan.writes.length, deleted: plan.deletes.length, failures };
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
    : { credential: applicationDefault(), projectId: target.projectId }, 'rebuild-pool-index');
  return { app, db: getFirestore(app, database) };
}

/** Runs the CLI and resolves to its exit code. Tests inject the emulator `db`. */
export async function run(argv, { db: injectedDb, env = process.env, log = consoleLog, now = new Date() } = {}) {
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
  log.info(`${options.apply ? 'APPLY' : 'dry run'} · ${where} · project ${target.projectId} · database ${options.database}`);
  let app = null;
  try {
    const db = injectedDb ?? ({ app } = await defaultDatabase(target, options.database)).db;
    const plan = await planRebuild(db);
    const creates = plan.writes.filter((write) => write.create).length;
    log.info(`Read ${plan.pools} pool documents (${plan.skippedPools} unusable).`);
    log.info(`Index: ${creates} to create, ${plan.writes.length - creates} to update, ${plan.deletes.length} to delete, `
      + `${plan.unchanged} unchanged.`);
    if (!options.apply) {
      log.info('Dry run: nothing written. Re-run with --apply (owner approval in production) to write the index.');
      return EXIT_OK;
    }
    const result = await applyRebuild(db, plan, now);
    log.info(`Wrote ${result.written}, deleted ${result.deleted}, failed ${result.failures.length}.`);
    for (const failure of result.failures) log.error(`  ${failure?.message ?? failure}`);
    return result.failures.length > 0 ? EXIT_FAILURES : EXIT_OK;
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

function isEntryPoint() {
  if (!process.argv[1]) return false;
  try {
    const invoked = realpathSync(resolve(process.argv[1])).normalize('NFC');
    return realpathSync(fileURLToPath(import.meta.url)).normalize('NFC') === invoked;
  } catch {
    return false;
  }
}

if (isEntryPoint()) {
  process.exitCode = await run(process.argv.slice(2));
}

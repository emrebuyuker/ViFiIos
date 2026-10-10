#!/usr/bin/env node
// Backs up, revokes and restores Firebase Storage download tokens.
//
// Every archive file's public `downloadURL` carries a `token=` query parameter that grants read
// access to anyone holding the link, bypassing storage.rules. The token lives in the object's
// custom metadata key `firebaseStorageDownloadTokens` (comma-separated). Removing that key makes
// those links stop working; the app then downloads with the user's Firebase ID + App Check tokens.
//
// Usage (run from firebase/, authenticated with Application Default Credentials, e.g.
// `gcloud auth application-default login` as a project owner):
//
//   node scripts/revoke-download-tokens.mjs backup  --out backups/tokens.json
//   node scripts/revoke-download-tokens.mjs revoke  --backup backups/tokens.json            # dry run
//   node scripts/revoke-download-tokens.mjs revoke  --backup backups/tokens.json --apply
//   node scripts/revoke-download-tokens.mjs restore --from backups/tokens.json [--apply]   # undo
//
// Options: --bucket <name> (default vifi-831a8.appspot.com), --prefix <p> (repeatable; default
// imagess/ and pdfs/), --concurrency <n> (default 16).
// Set STORAGE_EMULATOR_HOST (e.g. http://127.0.0.1:9199) to talk to a local emulator instead.
//
// Exit codes: 0 success, 1 at least one object failed, 2 usage error or refused.
//
// Limits (accepted, see storage.rules):
// - Revocation is a one-off cleanup of links that already leaked, not a lasting control. Firebase
//   Storage mints a new token the next time a client reads a token-less object through the Firebase
//   API (getMetadata/getDownloadURL), so any signed-in +90 user can still create a public link to a
//   file they may read.
// - Because of that, objects can gain tokens after a backup. A later `revoke --apply` refuses until
//   it has a fresh backup that covers them: take a new backup before every revoke run.
// - The backup is written owner-only (0600) and refused inside a git work tree unless git ignores it
//   (firebase/backups/ is ignored). Keep it off shared drives; delete it once it is no longer needed.

import { execFile } from 'node:child_process';
import { realpathSync } from 'node:fs';
import { mkdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseArgs } from 'node:util';

export const DEFAULT_BUCKET = 'vifi-831a8.appspot.com';
export const DEFAULT_PREFIXES = Object.freeze(['imagess/', 'pdfs/']);
export const DEFAULT_CONCURRENCY = 16;
export const TOKENS_KEY = 'firebaseStorageDownloadTokens';

export const EXIT_OK = 0;
export const EXIT_FAILURES = 1;
export const EXIT_REFUSED = 2;

const COMMANDS = new Set(['backup', 'revoke', 'restore']);
const RETRYABLE_STATUS = new Set([408, 429, 500, 502, 503, 504]);
const RETRYABLE_NETWORK_CODES = new Set(['ECONNRESET', 'ECONNREFUSED', 'ETIMEDOUT', 'EPIPE', 'EAI_AGAIN', 'ENETUNREACH', 'ECONNABORTED']);
const PROGRESS_EVERY = 100;
const LIST_PAGE_SIZE = 1000;

export const USAGE = `Usage:
  revoke-download-tokens.mjs backup  --out <file>               [--bucket <name>] [--prefix <p>]...
  revoke-download-tokens.mjs revoke  --backup <file> [--apply]  [--bucket <name>] [--prefix <p>]... [--concurrency <n>]
  revoke-download-tokens.mjs restore --from <file>   [--apply]  [--bucket <name>] [--concurrency <n>]

Without --apply, revoke and restore only report what they would change.`;

/** Wrong command-line usage. */
export class UsageError extends Error {}

/** The script will not run because doing so could lose tokens. */
export class RefusalError extends Error {}

// MARK: - Command line

/**
 * Parses `argv` (without the node binary and script path) into a validated command.
 * @returns {{ command: string, bucket: string, prefixes: string[], out?: string, backup?: string, from?: string, apply: boolean, concurrency: number }}
 */
export function parseCommandLine(argv) {
  let parsed;
  try {
    parsed = parseArgs({
      args: argv,
      allowPositionals: true,
      strict: true,
      options: {
        bucket: { type: 'string' },
        prefix: { type: 'string', multiple: true },
        out: { type: 'string' },
        backup: { type: 'string' },
        from: { type: 'string' },
        apply: { type: 'boolean', default: false },
        concurrency: { type: 'string' },
        help: { type: 'boolean', short: 'h', default: false },
      },
    });
  } catch (error) {
    throw new UsageError(error.message);
  }

  const { values, positionals } = parsed;
  if (values.help) {
    return { command: 'help' };
  }
  if (positionals.length !== 1 || !COMMANDS.has(positionals[0])) {
    throw new UsageError(`Expected exactly one command (backup, revoke or restore), got: ${positionals.join(' ') || 'none'}`);
  }
  const [command] = positionals;

  const required = { backup: 'out', revoke: 'backup', restore: 'from' }[command];
  const fileOptions = ['out', 'backup', 'from'];
  for (const option of fileOptions) {
    const value = values[option];
    if (option === required) {
      if (typeof value !== 'string' || value.trim() === '') {
        throw new UsageError(`${command} requires --${option} <file>`);
      }
    } else if (value !== undefined) {
      throw new UsageError(`--${option} is not valid for ${command}`);
    }
  }
  if (command === 'backup' && values.apply) {
    throw new UsageError('backup never changes objects; --apply is not valid for it');
  }
  if (command === 'restore' && values.prefix !== undefined) {
    throw new UsageError('restore works on the objects listed in the backup; --prefix is not valid for it');
  }

  const bucket = values.bucket ?? DEFAULT_BUCKET;
  if (!/^[a-z0-9][a-z0-9._-]{1,220}[a-z0-9]$/.test(bucket)) {
    throw new UsageError(`Invalid bucket name: ${bucket}`);
  }

  const prefixes = values.prefix ?? [...DEFAULT_PREFIXES];
  if (prefixes.some((prefix) => prefix.length === 0)) {
    throw new UsageError('--prefix must not be empty (an empty prefix would cover the whole bucket)');
  }

  let concurrency = DEFAULT_CONCURRENCY;
  if (values.concurrency !== undefined) {
    concurrency = Number(values.concurrency);
    if (!Number.isInteger(concurrency) || concurrency < 1 || concurrency > 64) {
      throw new UsageError('--concurrency must be an integer between 1 and 64');
    }
  }

  return {
    command,
    bucket,
    prefixes: [...new Set(prefixes)],
    out: values.out,
    backup: values.backup,
    from: values.from,
    apply: values.apply,
    concurrency,
  };
}

// MARK: - Pure planning logic

/** Splits a `firebaseStorageDownloadTokens` value into its tokens. */
export function parseTokens(value) {
  if (typeof value !== 'string') {
    return [];
  }
  return value.split(',').map((token) => token.trim()).filter((token) => token.length > 0);
}

/** The parts of an object resource this script cares about. */
export function describeObject(metadata) {
  return {
    name: metadata.name,
    generation: String(metadata.generation),
    metageneration: String(metadata.metageneration),
    tokens: parseTokens(metadata.metadata?.[TOKENS_KEY]),
  };
}

/** Validates parsed backup JSON: `[{ name, generation, tokens }]` with unique names. Throws `RefusalError`. */
export function validateBackup(json) {
  if (!Array.isArray(json)) {
    throw new RefusalError('Backup must be a JSON array of { name, generation, tokens }');
  }
  const names = new Set();
  json.forEach((entry, index) => {
    const valid = entry !== null && typeof entry === 'object'
      && typeof entry.name === 'string' && entry.name.length > 0
      && typeof entry.generation === 'string' && /^[0-9]+$/.test(entry.generation)
      && Array.isArray(entry.tokens) && entry.tokens.every((token) => typeof token === 'string' && token.length > 0 && !token.includes(','));
    if (!valid) {
      throw new RefusalError(`Backup entry #${index} is malformed: ${JSON.stringify(entry)}`);
    }
    if (names.has(entry.name)) {
      throw new RefusalError(`Backup lists ${entry.name} more than once`);
    }
    names.add(entry.name);
  });
  return json;
}

/**
 * Decides which objects `revoke` changes and whether the backup allows it.
 *
 * An object is covered when the backup has the same name and generation and contains every token
 * the object carries now, so `restore` could bring all of them back.
 * @param {Array<{name: string, generation: string, metageneration: string, tokens: string[]}>} objects
 * @param {Array<{name: string, generation: string, tokens: string[]}> | null} backup `null` if there is no backup file.
 */
export function planRevoke(objects, backup) {
  const changes = objects.filter((object) => object.tokens.length > 0);
  const uncovered = [];
  if (backup === null) {
    return { scanned: objects.length, changes, alreadyClean: objects.length - changes.length, uncovered, backupMissing: true };
  }
  const backupByName = new Map(backup.map((entry) => [entry.name, entry]));
  for (const object of changes) {
    const entry = backupByName.get(object.name);
    if (!entry) {
      uncovered.push({ name: object.name, reason: 'not in backup' });
    } else if (entry.generation !== object.generation) {
      uncovered.push({ name: object.name, reason: `backup has generation ${entry.generation}, object has ${object.generation}` });
    } else if (!object.tokens.every((token) => entry.tokens.includes(token))) {
      uncovered.push({ name: object.name, reason: 'object has tokens the backup does not contain' });
    }
  }
  return { scanned: objects.length, changes, alreadyClean: objects.length - changes.length, uncovered, backupMissing: false };
}

/** Why `revoke --apply` must not run for `plan`, or `null` when it may. */
export function revokeRefusalReason(plan) {
  if (plan.backupMissing) {
    return 'the backup file does not exist; run `backup` first';
  }
  if (plan.uncovered.length > 0) {
    return `${plan.uncovered.length} object(s) with tokens are not covered by the backup; run a fresh \`backup\``;
  }
  return null;
}

/**
 * Decides what `restore` does for one backup entry given the object's current state (`null` if gone).
 * @returns {{ action: 'skip' | 'restore' | 'conflict', reason: string, tokens?: string[] }}
 */
export function decideRestore(entry, current) {
  if (entry.tokens.length === 0) {
    return { action: 'skip', reason: 'no tokens in backup' };
  }
  if (current === null) {
    return { action: 'conflict', reason: 'object no longer exists' };
  }
  if (current.generation !== entry.generation) {
    return { action: 'conflict', reason: `object was replaced since the backup (generation ${entry.generation} -> ${current.generation})` };
  }
  if (entry.tokens.every((token) => current.tokens.includes(token))) {
    return { action: 'skip', reason: 'tokens already present' };
  }
  return { action: 'restore', reason: 'tokens missing', tokens: [...new Set([...entry.tokens, ...current.tokens])] };
}

// MARK: - Retry and concurrency

/** HTTP status of a @google-cloud/storage error, if any. */
export function errorStatus(error) {
  if (typeof error?.code === 'number') {
    return error.code;
  }
  const status = error?.response?.status ?? error?.response?.statusCode ?? error?.status;
  return typeof status === 'number' ? status : undefined;
}

/** 408/429/5xx and transient network failures are retried; everything else fails immediately. */
export function isRetryable(error) {
  const status = errorStatus(error);
  if (status !== undefined) {
    return RETRYABLE_STATUS.has(status);
  }
  return RETRYABLE_NETWORK_CODES.has(error?.code) || RETRYABLE_NETWORK_CODES.has(error?.cause?.code);
}

/** Delay before retry number `attempt` (1-based): exponential with jitter in [50%, 100%], capped. */
export function backoffDelay(attempt, { baseDelayMs = 500, maxDelayMs = 30_000, random = Math.random } = {}) {
  const exponential = Math.min(maxDelayMs, baseDelayMs * 2 ** (attempt - 1));
  return Math.round(exponential * (0.5 + random() / 2));
}

const delay = (milliseconds) => new Promise((resolveDelay) => {
  setTimeout(resolveDelay, milliseconds);
});

/** Runs `operation`, retrying retryable failures with exponential backoff. */
export async function withRetry(operation, { attempts = 6, sleep = delay, ...backoff } = {}) {
  for (let attempt = 1; ; attempt += 1) {
    try {
      return await operation();
    } catch (error) {
      if (attempt >= attempts || !isRetryable(error)) {
        throw error;
      }
      await sleep(backoffDelay(attempt, backoff));
    }
  }
}

/** Maps `items` with at most `limit` `worker` calls in flight. Never rejects; returns `{ item, value }` or `{ item, error }`. */
export async function mapWithConcurrency(items, limit, worker) {
  const results = new Array(items.length);
  let next = 0;
  async function lane() {
    while (next < items.length) {
      const index = next;
      next += 1;
      try {
        results[index] = { item: items[index], value: await worker(items[index], index) };
      } catch (error) {
        results[index] = { item: items[index], error };
      }
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, lane));
  return results;
}

// MARK: - Storage operations

async function listObjects(bucket, prefixes) {
  const objects = [];
  for (const prefix of prefixes) {
    let pageToken;
    do {
      const query = { prefix, autoPaginate: false, maxResults: LIST_PAGE_SIZE, pageToken };
      const [files, nextQuery] = await withRetry(() => bucket.getFiles(query));
      for (const file of files) {
        objects.push(describeObject(file.metadata));
      }
      pageToken = nextQuery?.pageToken;
    } while (pageToken);
  }
  const seen = new Set();
  return objects.filter((object) => !seen.has(object.name) && seen.add(object.name));
}

async function currentState(file) {
  try {
    const [metadata] = await withRetry(() => file.getMetadata());
    return describeObject(metadata);
  } catch (error) {
    if (errorStatus(error) === 404) {
      return null;
    }
    throw error;
  }
}

/**
 * Patches the tokens of `object` guarded by generation/metageneration preconditions, so a file
 * replaced or edited in the meantime is never touched. `isDone` checks a state for success; it is
 * also used to recognise a 412 caused by our own earlier attempt whose response was lost.
 */
async function patchTokens(file, object, value, isDone) {
  const preconditions = { ifGenerationMatch: object.generation, ifMetagenerationMatch: object.metageneration };
  let updated;
  try {
    [updated] = await withRetry(() => file.setMetadata({ metadata: { [TOKENS_KEY]: value } }, preconditions));
  } catch (error) {
    if (errorStatus(error) !== 412) {
      throw error;
    }
    const current = await currentState(file);
    if (current && current.generation === object.generation && isDone(current)) {
      return;
    }
    throw new Error('object changed while the script was running (precondition failed)', { cause: error });
  }
  if (!updated || !isDone(describeObject(updated))) {
    throw new Error('the update was accepted but the tokens are not as expected');
  }
}

async function readBackupFile(path) {
  let text;
  try {
    text = await readFile(path, 'utf8');
  } catch (error) {
    if (error.code === 'ENOENT') {
      return null;
    }
    throw error;
  }
  let json;
  try {
    json = JSON.parse(text);
  } catch (error) {
    throw new RefusalError(`Backup ${path} is not valid JSON: ${error.message}`);
  }
  return validateBackup(json);
}

/**
 * Refuses a path inside a git work tree that git would not ignore: a backup holds a working public
 * link to every archive file and must never be committed. Outside a repository (or without git) it
 * does nothing.
 */
function assertNotCommittable(path) {
  return new Promise((resolvePromise, reject) => {
    execFile('git', ['-C', dirname(path), 'check-ignore', '--quiet', '--', path], (error) => {
      // 0: ignored. 1: inside a work tree but not ignored. 128 / ENOENT: not a repository / no git.
      if (error?.code === 1) {
        reject(new RefusalError(`${path} is inside a git work tree and not git-ignored; write the backup to firebase/backups/ or outside the repository`));
      } else {
        resolvePromise();
      }
    });
  });
}

async function writeJsonExclusively(path, value) {
  try {
    await stat(path);
    throw new RefusalError(`${path} already exists; choose a new --out file so an earlier backup is never overwritten`);
  } catch (error) {
    if (error instanceof RefusalError) {
      throw error;
    }
    if (error.code !== 'ENOENT') {
      throw error;
    }
  }
  // Owner-only: the backup is as sensitive as the download tokens it holds.
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  await assertNotCommittable(resolve(path));
  const temporary = `${path}.${process.pid}.tmp`;
  try {
    await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { flag: 'wx', mode: 0o600 });
    await rename(temporary, path);
  } catch (error) {
    await rm(temporary, { force: true });
    throw error;
  }
}

function progressReporter(total, label, log) {
  let done = 0;
  return () => {
    done += 1;
    if (done % PROGRESS_EVERY === 0 || done === total) {
      log.progress(`${label}: ${done}/${total}`);
    }
  };
}

function reportFailures(results, log) {
  const failures = results.filter((result) => result.error);
  for (const { item, error } of failures) {
    log.error(`FAILED ${item.name}: ${error.message}`);
  }
  return failures.length;
}

// MARK: - Commands

async function backupCommand(options, bucket, log) {
  const objects = await listObjects(bucket, options.prefixes);
  const entries = objects.map(({ name, generation, tokens }) => ({ name, generation, tokens }));
  await writeJsonExclusively(options.out, entries);
  const withTokens = entries.filter((entry) => entry.tokens.length > 0).length;
  log.info(`Backed up ${entries.length} object(s) (${withTokens} with download tokens) to ${resolve(options.out)}`);
  return EXIT_OK;
}

async function revokeCommand(options, bucket, log) {
  const backup = await readBackupFile(options.backup);
  const objects = await listObjects(bucket, options.prefixes);
  const plan = planRevoke(objects, backup);
  const refusal = revokeRefusalReason(plan);

  log.info(`Scanned ${plan.scanned} object(s): ${plan.changes.length} with download tokens, ${plan.alreadyClean} without.`);
  for (const { name, reason } of plan.uncovered.slice(0, 20)) {
    log.error(`NOT COVERED ${name}: ${reason}`);
  }
  if (plan.uncovered.length > 20) {
    log.error(`... and ${plan.uncovered.length - 20} more not covered`);
  }
  if (refusal) {
    log.error(`${options.apply ? 'Refusing to apply' : 'Apply would be refused'}: ${refusal}.`);
    return EXIT_REFUSED;
  }
  if (!options.apply) {
    log.info(`Dry run: would remove ${TOKENS_KEY} from ${plan.changes.length} object(s). Re-run with --apply to do it.`);
    return EXIT_OK;
  }

  const tick = progressReporter(plan.changes.length, 'Revoking', log);
  const results = await mapWithConcurrency(plan.changes, options.concurrency, async (object) => {
    try {
      await patchTokens(bucket.file(object.name), object, null, (state) => state.tokens.length === 0);
    } finally {
      tick();
    }
  });
  const failed = reportFailures(results, log);
  log.info(`Revoked tokens on ${results.length - failed} object(s); ${failed} failed.`);
  return failed > 0 ? EXIT_FAILURES : EXIT_OK;
}

async function restoreCommand(options, bucket, log) {
  const backup = await readBackupFile(options.from);
  if (backup === null) {
    throw new RefusalError(`Backup ${options.from} does not exist`);
  }
  const entries = backup.filter((entry) => entry.tokens.length > 0);
  const tick = progressReporter(entries.length, options.apply ? 'Restoring' : 'Checking', log);
  const results = await mapWithConcurrency(entries, options.concurrency, async (entry) => {
    try {
      const file = bucket.file(entry.name);
      const current = await currentState(file);
      const decision = decideRestore(entry, current);
      if (decision.action === 'conflict') {
        throw new Error(`conflict: ${decision.reason}`);
      }
      if (decision.action === 'restore' && options.apply) {
        await patchTokens(file, current, decision.tokens.join(','), (state) => entry.tokens.every((token) => state.tokens.includes(token)));
      }
      return decision.action;
    } finally {
      tick();
    }
  });
  const failed = reportFailures(results, log);
  const restored = results.filter((result) => result.value === 'restore').length;
  const alreadyPresent = results.filter((result) => result.value === 'skip').length;
  const verb = options.apply ? 'Restored' : 'Dry run: would restore';
  log.info(`${verb} tokens on ${restored} object(s); ${alreadyPresent} already had them; ${failed} failed.`);
  if (!options.apply && restored > 0) {
    log.info('Re-run with --apply to write them back.');
  }
  return failed > 0 ? EXIT_FAILURES : EXIT_OK;
}

const consoleLog = {
  info: (message) => console.log(message),
  progress: (message) => console.error(message),
  error: (message) => console.error(message),
};

/**
 * Runs the CLI and resolves to its exit code.
 * @param {string[]} argv Arguments after the script path.
 * @param {{ createStorage?: () => Promise<object>, log?: typeof consoleLog }} [dependencies]
 */
export async function run(argv, { createStorage = defaultStorage, log = consoleLog } = {}) {
  let options;
  try {
    options = parseCommandLine(argv);
  } catch (error) {
    if (error instanceof UsageError) {
      log.error(`${error.message}\n\n${USAGE}`);
      return EXIT_REFUSED;
    }
    throw error;
  }
  if (options.command === 'help') {
    log.info(USAGE);
    return EXIT_OK;
  }

  const endpoint = process.env.STORAGE_EMULATOR_HOST ? `emulator ${process.env.STORAGE_EMULATOR_HOST}` : 'PRODUCTION Cloud Storage';
  const mode = options.command === 'backup' ? 'read-only' : (options.apply ? 'APPLY' : 'dry run');
  log.info(`${options.command} gs://${options.bucket} via ${endpoint} (${mode})`);

  try {
    const bucket = (await createStorage()).bucket(options.bucket);
    const command = { backup: backupCommand, revoke: revokeCommand, restore: restoreCommand }[options.command];
    return await command(options, bucket, log);
  } catch (error) {
    if (error instanceof RefusalError) {
      log.error(`Refused: ${error.message}`);
      return EXIT_REFUSED;
    }
    log.error(`Error: ${error.message}`);
    return EXIT_FAILURES;
  }
}

async function defaultStorage() {
  const { Storage } = await import('@google-cloud/storage');
  // Retries are handled by `withRetry`, so the library must not retry on its own as well.
  return new Storage({ retryOptions: { autoRetry: false } });
}

/** True when this file is the script node was started with (not when imported by the tests). */
function isEntryPoint() {
  if (!process.argv[1]) {
    return false;
  }
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

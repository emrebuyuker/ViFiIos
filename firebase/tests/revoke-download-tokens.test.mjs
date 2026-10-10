// Tests for scripts/revoke-download-tokens.mjs.
//
// The pure logic is tested directly. The CLI is run as a child process against an in-memory fake
// of the Cloud Storage JSON API (tests/fake-gcs-server.mjs) through STORAGE_EMULATOR_HOST, so these
// tests never need credentials and can never reach a real bucket.

import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { after, afterEach, before, beforeEach, describe, test } from 'node:test';
import {
  DEFAULT_BUCKET, DEFAULT_CONCURRENCY, DEFAULT_PREFIXES, EXIT_FAILURES, EXIT_OK, EXIT_REFUSED, RefusalError, UsageError,
  backoffDelay, decideRestore, isRetryable, mapWithConcurrency, parseCommandLine, parseTokens, planRevoke,
  revokeRefusalReason, validateBackup, withRetry,
} from '../scripts/revoke-download-tokens.mjs';
import { startFakeGcs } from './fake-gcs-server.mjs';

const SCRIPT = fileURLToPath(new URL('../scripts/revoke-download-tokens.mjs', import.meta.url));
const TEST_BUCKET = 'demo-vifi-test-bucket';

const object = (name, tokens, generation = '1', metageneration = '1') => ({ name, generation, metageneration, tokens });
const httpError = (code) => Object.assign(new Error(`HTTP ${code}`), { code });

describe('parseCommandLine', () => {
  test('backup uses the default bucket and prefixes', () => {
    assert.deepEqual(parseCommandLine(['backup', '--out', 'b.json']), {
      command: 'backup', bucket: DEFAULT_BUCKET, prefixes: [...DEFAULT_PREFIXES], out: 'b.json', backup: undefined, from: undefined,
      apply: false, concurrency: DEFAULT_CONCURRENCY,
    });
  });

  test('revoke and restore are dry runs unless --apply', () => {
    assert.equal(parseCommandLine(['revoke', '--backup', 'b.json']).apply, false);
    assert.equal(parseCommandLine(['revoke', '--backup', 'b.json', '--apply']).apply, true);
    assert.equal(parseCommandLine(['restore', '--from', 'b.json']).apply, false);
    assert.equal(parseCommandLine(['restore', '--from', 'b.json', '--apply']).apply, true);
  });

  test('bucket, prefixes and concurrency can be overridden', () => {
    const options = parseCommandLine(['revoke', '--backup', 'b.json', '--bucket', 'other-bucket', '--prefix', 'a/', '--prefix', 'b/', '--prefix', 'a/',
      '--concurrency', '4']);
    assert.equal(options.bucket, 'other-bucket');
    assert.deepEqual(options.prefixes, ['a/', 'b/']);
    assert.equal(options.concurrency, 4);
  });

  test('help', () => {
    assert.deepEqual(parseCommandLine(['--help']), { command: 'help' });
  });

  const invalid = {
    'no command': [],
    'unknown command': ['delete'],
    'two commands': ['backup', 'revoke', '--out', 'x'],
    'backup without --out': ['backup'],
    'revoke without --backup': ['revoke', '--apply'],
    'restore without --from': ['restore'],
    'blank --out': ['backup', '--out', ' '],
    'backup with --apply': ['backup', '--out', 'x', '--apply'],
    'revoke with --out': ['revoke', '--backup', 'x', '--out', 'y'],
    'restore with --backup': ['restore', '--from', 'x', '--backup', 'y'],
    'restore with --prefix': ['restore', '--from', 'x', '--prefix', 'a/'],
    'empty prefix': ['backup', '--out', 'x', '--prefix', ''],
    'bad bucket': ['backup', '--out', 'x', '--bucket', 'gs://bucket'],
    'concurrency 0': ['revoke', '--backup', 'x', '--concurrency', '0'],
    'concurrency 65': ['revoke', '--backup', 'x', '--concurrency', '65'],
    'concurrency not a number': ['revoke', '--backup', 'x', '--concurrency', 'many'],
    'unknown flag': ['revoke', '--backup', 'x', '--force'],
  };
  for (const [label, argv] of Object.entries(invalid)) {
    test(`rejects ${label}`, () => {
      assert.throws(() => parseCommandLine(argv), UsageError);
    });
  }
});

describe('parseTokens', () => {
  test('splits, trims and drops empties', () => {
    assert.deepEqual(parseTokens('a,b'), ['a', 'b']);
    assert.deepEqual(parseTokens(' a , ,b,'), ['a', 'b']);
    assert.deepEqual(parseTokens(''), []);
    assert.deepEqual(parseTokens(undefined), []);
    assert.deepEqual(parseTokens(null), []);
  });
});

describe('validateBackup', () => {
  test('accepts a well-formed backup', () => {
    const backup = [{ name: 'imagess/a.jpg', generation: '17', tokens: ['t1'] }, { name: 'pdfs/b.pdf', generation: '18', tokens: [] }];
    assert.equal(validateBackup(backup), backup);
  });

  const invalid = {
    'not an array': { name: 'x' },
    'missing name': [{ generation: '1', tokens: [] }],
    'numeric generation': [{ name: 'x', generation: 1, tokens: [] }],
    'tokens not an array': [{ name: 'x', generation: '1', tokens: 't1' }],
    'token with a comma': [{ name: 'x', generation: '1', tokens: ['a,b'] }],
    'duplicate names': [{ name: 'x', generation: '1', tokens: [] }, { name: 'x', generation: '2', tokens: [] }],
    'null entry': [null],
  };
  for (const [label, backup] of Object.entries(invalid)) {
    test(`refuses ${label}`, () => {
      assert.throws(() => validateBackup(backup), RefusalError);
    });
  }
});

describe('planRevoke', () => {
  const objects = [object('imagess/a.jpg', ['t1']), object('imagess/b.jpg', []), object('pdfs/c.pdf', ['t2', 't3'], '5')];

  test('changes only objects with tokens', () => {
    const plan = planRevoke(objects, [
      { name: 'imagess/a.jpg', generation: '1', tokens: ['t1'] },
      { name: 'imagess/b.jpg', generation: '1', tokens: [] },
      { name: 'pdfs/c.pdf', generation: '5', tokens: ['t3', 't2'] },
    ]);
    assert.deepEqual(plan.changes.map((change) => change.name), ['imagess/a.jpg', 'pdfs/c.pdf']);
    assert.equal(plan.scanned, 3);
    assert.equal(plan.alreadyClean, 1);
    assert.deepEqual(plan.uncovered, []);
    assert.equal(revokeRefusalReason(plan), null);
  });

  test('refuses without a backup file', () => {
    const plan = planRevoke(objects, null);
    assert.equal(plan.backupMissing, true);
    assert.match(revokeRefusalReason(plan), /does not exist/);
  });

  test('refuses objects the backup does not fully cover', () => {
    const plan = planRevoke(objects, [
      { name: 'imagess/a.jpg', generation: '2', tokens: ['t1'] }, // Replaced since the backup.
      { name: 'pdfs/c.pdf', generation: '5', tokens: ['t2'] }, // Missing t3.
    ]);
    assert.deepEqual(plan.uncovered.map((entry) => entry.name), ['imagess/a.jpg', 'pdfs/c.pdf']);
    assert.match(revokeRefusalReason(plan), /2 object\(s\)/);

    const missing = planRevoke(objects, [{ name: 'imagess/a.jpg', generation: '1', tokens: ['t1'] }]);
    assert.deepEqual(missing.uncovered, [{ name: 'pdfs/c.pdf', reason: 'not in backup' }]);
  });

  test('an empty plan is allowed', () => {
    assert.equal(revokeRefusalReason(planRevoke([object('imagess/b.jpg', [])], [])), null);
  });
});

describe('decideRestore', () => {
  const entry = { name: 'imagess/a.jpg', generation: '1', tokens: ['t1', 't2'] };

  test('restores missing tokens and keeps newer ones', () => {
    assert.deepEqual(decideRestore(entry, object('imagess/a.jpg', [])), { action: 'restore', reason: 'tokens missing', tokens: ['t1', 't2'] });
    assert.deepEqual(decideRestore(entry, object('imagess/a.jpg', ['t9', 't2'])).tokens, ['t1', 't2', 't9']);
  });

  test('skips entries without tokens and objects that already have them', () => {
    assert.equal(decideRestore({ ...entry, tokens: [] }, null).action, 'skip');
    assert.equal(decideRestore(entry, object('imagess/a.jpg', ['t2', 't1', 't3'])).action, 'skip');
  });

  test('reports deleted or replaced objects as conflicts', () => {
    assert.equal(decideRestore(entry, null).action, 'conflict');
    assert.equal(decideRestore(entry, object('imagess/a.jpg', [], '2')).action, 'conflict');
  });
});

describe('retry and concurrency helpers', () => {
  test('isRetryable', () => {
    for (const code of [408, 429, 500, 502, 503, 504]) {
      assert.equal(isRetryable(httpError(code)), true, `${code}`);
    }
    for (const code of [400, 401, 403, 404, 412]) {
      assert.equal(isRetryable(httpError(code)), false, `${code}`);
    }
    assert.equal(isRetryable(Object.assign(new Error('reset'), { code: 'ECONNRESET' })), true);
    assert.equal(isRetryable(new Error('boom')), false);
  });

  test('backoffDelay grows exponentially, is capped and jittered', () => {
    const max = (attempt) => backoffDelay(attempt, { random: () => 1 });
    assert.deepEqual([1, 2, 3, 4].map(max), [500, 1000, 2000, 4000]);
    assert.equal(max(20), 30_000);
    assert.equal(backoffDelay(1, { random: () => 0 }), 250);
  });

  test('withRetry retries retryable errors, then succeeds', async () => {
    const sleeps = [];
    let calls = 0;
    const value = await withRetry(async () => {
      calls += 1;
      if (calls < 3) {
        throw httpError(calls === 1 ? 429 : 503);
      }
      return 'ok';
    }, { sleep: async (ms) => sleeps.push(ms), random: () => 1 });
    assert.equal(value, 'ok');
    assert.equal(calls, 3);
    assert.deepEqual(sleeps, [500, 1000]);
  });

  test('withRetry fails fast on non-retryable errors and gives up after `attempts`', async () => {
    let calls = 0;
    await assert.rejects(withRetry(async () => {
      calls += 1;
      throw httpError(403);
    }, { sleep: async () => {} }), /HTTP 403/);
    assert.equal(calls, 1);

    calls = 0;
    await assert.rejects(withRetry(async () => {
      calls += 1;
      throw httpError(500);
    }, { attempts: 4, sleep: async () => {} }), /HTTP 500/);
    assert.equal(calls, 4);
  });

  test('mapWithConcurrency keeps order, captures errors and bounds parallelism', async () => {
    let inFlight = 0;
    let peak = 0;
    const results = await mapWithConcurrency([1, 2, 3, 4, 5, 6, 7], 3, async (item) => {
      inFlight += 1;
      peak = Math.max(peak, inFlight);
      await new Promise((resolve) => {
        setTimeout(resolve, 5);
      });
      inFlight -= 1;
      if (item === 4) {
        throw new Error('four');
      }
      return item * 10;
    });
    assert.equal(peak, 3);
    assert.deepEqual(results.map((result) => result.value ?? result.error.message), [10, 20, 30, 'four', 50, 60, 70]);
    assert.deepEqual(await mapWithConcurrency([], 16, async () => 1), []);
  });
});

describe('CLI against a fake Cloud Storage API', () => {
  let fake;
  let workDirectory;

  /** Runs the script with STORAGE_EMULATOR_HOST pointing at the fake; resolves to { code, stdout, stderr }. */
  function cli(...args) {
    const env = { ...process.env, STORAGE_EMULATOR_HOST: fake.url };
    delete env.GOOGLE_APPLICATION_CREDENTIALS;
    return new Promise((resolve) => {
      execFile(process.execPath, [SCRIPT, ...args, '--bucket', TEST_BUCKET], { env, cwd: workDirectory }, (error, stdout, stderr) => {
        resolve({ code: error ? error.code : 0, stdout, stderr });
      });
    });
  }

  const patches = () => fake.requests.filter((request) => request.method === 'PATCH');
  const tokensOf = (name) => parseTokens(fake.get(TEST_BUCKET, name)?.metadata?.firebaseStorageDownloadTokens);
  const readBackup = async (name) => JSON.parse(await readFile(join(workDirectory, name), 'utf8'));

  before(async () => {
    fake = await startFakeGcs();
  });

  after(async () => {
    await fake.close();
  });

  beforeEach(async () => {
    fake.reset();
    workDirectory = await mkdtemp(join(tmpdir(), 'vifi-revoke-test-'));
    fake.put(TEST_BUCKET, 'imagess/a.jpg', { tokens: ['ta'] });
    fake.put(TEST_BUCKET, 'imagess/b.jpg', { tokens: ['tb1', 'tb2'], metadata: { uploadedBy: 'admin' } });
    fake.put(TEST_BUCKET, 'imagess/c.jpg', { tokens: ['tc'] });
    fake.put(TEST_BUCKET, 'imagess/no-token.jpg');
    fake.put(TEST_BUCKET, 'pdfs/d.pdf', { tokens: ['td'] });
    fake.put(TEST_BUCKET, 'other/keep.txt', { tokens: ['tk'] });
  });

  afterEach(async () => {
    await rm(workDirectory, { recursive: true, force: true });
  });

  test('backup, dry run, revoke, restore round trip', async () => {
    const backup = await cli('backup', '--out', 'backups/tokens.json');
    assert.equal(backup.code, EXIT_OK, backup.stderr);
    assert.match(backup.stdout, /via emulator http:\/\/127\.0\.0\.1/);
    const entries = await readBackup('backups/tokens.json');
    assert.deepEqual(entries.map((entry) => [entry.name, entry.tokens]), [
      ['imagess/a.jpg', ['ta']],
      ['imagess/b.jpg', ['tb1', 'tb2']],
      ['imagess/c.jpg', ['tc']],
      ['imagess/no-token.jpg', []],
      ['pdfs/d.pdf', ['td']],
    ]);
    assert.equal(entries[0].generation, fake.get(TEST_BUCKET, 'imagess/a.jpg').generation);

    const dryRun = await cli('revoke', '--backup', 'backups/tokens.json');
    assert.equal(dryRun.code, EXIT_OK, dryRun.stderr);
    assert.match(dryRun.stdout, /would remove firebaseStorageDownloadTokens from 4 object\(s\)/);
    assert.equal(patches().length, 0);

    const revoke = await cli('revoke', '--backup', 'backups/tokens.json', '--apply');
    assert.equal(revoke.code, EXIT_OK, revoke.stderr);
    assert.match(revoke.stdout, /Revoked tokens on 4 object\(s\); 0 failed/);
    for (const name of ['imagess/a.jpg', 'imagess/b.jpg', 'imagess/c.jpg', 'pdfs/d.pdf']) {
      assert.deepEqual(tokensOf(name), [], name);
    }
    assert.deepEqual(fake.get(TEST_BUCKET, 'imagess/b.jpg').metadata, { uploadedBy: 'admin' }, 'other custom metadata is kept');
    assert.deepEqual(tokensOf('other/keep.txt'), ['tk'], 'objects outside the prefixes are untouched');
    for (const request of patches()) {
      assert.deepEqual(request.body, { metadata: { firebaseStorageDownloadTokens: null } });
      assert.ok(request.query.ifGenerationMatch && request.query.ifMetagenerationMatch, 'PATCH carries preconditions');
    }

    const again = await cli('revoke', '--backup', 'backups/tokens.json', '--apply');
    assert.equal(again.code, EXIT_OK, again.stderr);
    assert.match(again.stdout, /0 with download tokens/);

    fake.requests.length = 0;
    const restoreDryRun = await cli('restore', '--from', 'backups/tokens.json');
    assert.equal(restoreDryRun.code, EXIT_OK, restoreDryRun.stderr);
    assert.match(restoreDryRun.stdout, /would restore tokens on 4 object\(s\)/);
    assert.equal(patches().length, 0);

    const restore = await cli('restore', '--from', 'backups/tokens.json', '--apply');
    assert.equal(restore.code, EXIT_OK, restore.stderr);
    assert.deepEqual(tokensOf('imagess/a.jpg'), ['ta']);
    assert.deepEqual(tokensOf('imagess/b.jpg'), ['tb1', 'tb2']);
    assert.deepEqual(tokensOf('pdfs/d.pdf'), ['td']);
    assert.equal(fake.get(TEST_BUCKET, 'imagess/b.jpg').metadata.uploadedBy, 'admin');

    const restoreAgain = await cli('restore', '--from', 'backups/tokens.json', '--apply');
    assert.equal(restoreAgain.code, EXIT_OK, restoreAgain.stderr);
    assert.match(restoreAgain.stdout, /on 0 object\(s\); 4 already had them/);
  });

  test('refuses --apply without a backup file and changes nothing', async () => {
    const result = await cli('revoke', '--backup', 'missing.json', '--apply');
    assert.equal(result.code, EXIT_REFUSED);
    assert.match(result.stderr, /Refusing to apply: the backup file does not exist/);
    assert.equal(patches().length, 0);
    assert.deepEqual(tokensOf('imagess/a.jpg'), ['ta']);
  });

  test('refuses --apply when the backup does not cover every object', async () => {
    assert.equal((await cli('backup', '--out', 'tokens.json')).code, EXIT_OK);
    fake.put(TEST_BUCKET, 'imagess/new-after-backup.jpg', { tokens: ['tn'] });
    const result = await cli('revoke', '--backup', 'tokens.json', '--apply');
    assert.equal(result.code, EXIT_REFUSED);
    assert.match(result.stderr, /NOT COVERED imagess\/new-after-backup\.jpg: not in backup/);
    assert.equal(patches().length, 0);
  });

  test('refuses a malformed backup', async () => {
    await writeFile(join(workDirectory, 'broken.json'), '{"not":"an array"}');
    const result = await cli('revoke', '--backup', 'broken.json', '--apply');
    assert.equal(result.code, EXIT_REFUSED);
    assert.equal(patches().length, 0);
  });

  test('backup never overwrites an existing file', async () => {
    await writeFile(join(workDirectory, 'tokens.json'), '[]');
    const result = await cli('backup', '--out', 'tokens.json');
    assert.equal(result.code, EXIT_REFUSED);
    assert.equal(await readFile(join(workDirectory, 'tokens.json'), 'utf8'), '[]');
  });

  test('retries 429 and 5xx responses', async () => {
    assert.equal((await cli('backup', '--out', 'tokens.json')).code, EXIT_OK);
    fake.failNext('PATCH', 'imagess/a.jpg', 429, 503);
    fake.failNext('GET', '', 500);
    const result = await cli('revoke', '--backup', 'tokens.json', '--apply');
    assert.equal(result.code, EXIT_OK, result.stderr);
    assert.deepEqual(tokensOf('imagess/a.jpg'), []);
    assert.equal(patches().filter((request) => request.name === 'imagess/a.jpg').length, 3);
  });

  test('reports per-object failures, finishes the rest and exits non-zero', async () => {
    assert.equal((await cli('backup', '--out', 'tokens.json')).code, EXIT_OK);
    fake.failNext('PATCH', 'imagess/a.jpg', 403);
    fake.failNext('PATCH', 'imagess/c.jpg', 412); // Changed by someone else meanwhile: tokens still there.
    const result = await cli('revoke', '--backup', 'tokens.json', '--apply', '--concurrency', '2');
    assert.equal(result.code, EXIT_FAILURES);
    assert.match(result.stderr, /FAILED imagess\/a\.jpg/);
    assert.match(result.stderr, /FAILED imagess\/c\.jpg: object changed while the script was running/);
    assert.match(result.stdout, /Revoked tokens on 2 object\(s\); 2 failed/);
    assert.deepEqual(tokensOf('imagess/a.jpg'), ['ta']);
    assert.deepEqual(tokensOf('imagess/b.jpg'), []);
  });

  test('restore reports objects replaced or deleted since the backup', async () => {
    assert.equal((await cli('backup', '--out', 'tokens.json')).code, EXIT_OK);
    assert.equal((await cli('revoke', '--backup', 'tokens.json', '--apply')).code, EXIT_OK);
    fake.put(TEST_BUCKET, 'imagess/a.jpg'); // Re-uploaded: new generation.
    fake.delete(TEST_BUCKET, 'pdfs/d.pdf');
    const result = await cli('restore', '--from', 'tokens.json', '--apply');
    assert.equal(result.code, EXIT_FAILURES);
    assert.match(result.stderr, /FAILED imagess\/a\.jpg: conflict: object was replaced/);
    assert.match(result.stderr, /FAILED pdfs\/d\.pdf: conflict: object no longer exists/);
    assert.deepEqual(tokensOf('imagess/a.jpg'), []);
    assert.deepEqual(tokensOf('imagess/b.jpg'), ['tb1', 'tb2']);
  });

  test('usage errors exit with 2', async () => {
    const result = await cli('revoke');
    assert.equal(result.code, EXIT_REFUSED);
    assert.match(result.stderr, /revoke requires --backup/);
  });
});

// Runs scripts/revoke-download-tokens.mjs against the Firebase Storage emulator's Cloud Storage
// JSON API (started by `npm test`). Skipped when the emulator is not running.
//
// Only `backup` and the `revoke` dry run are checked here. The emulator does not model token
// removal: it moves `firebaseStorageDownloadTokens` out of the custom metadata into a separate
// field when an object is written, and keeps that field when the key is later PATCHed to null.
// The apply / restore paths are covered against the GCS-semantics fake in
// revoke-download-tokens.test.mjs instead.

import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { after, before, describe, test } from 'node:test';
import { Storage } from '@google-cloud/storage';
import { assertLocalEmulators } from './helpers.mjs';

const SCRIPT = fileURLToPath(new URL('../scripts/revoke-download-tokens.mjs', import.meta.url));
const BUCKET = 'demo-vifi-revoke-test';
const emulatorHost = process.env.FIREBASE_STORAGE_EMULATOR_HOST;

describe('revoke-download-tokens against the Storage emulator', { skip: emulatorHost ? false : 'Storage emulator is not running' }, () => {
  let storageEmulatorUrl;
  let workDirectory;

  function cli(...args) {
    const env = { ...process.env, STORAGE_EMULATOR_HOST: storageEmulatorUrl };
    delete env.GOOGLE_APPLICATION_CREDENTIALS;
    return new Promise((resolve) => {
      execFile(process.execPath, [SCRIPT, ...args, '--bucket', BUCKET], { env, cwd: workDirectory }, (error, stdout, stderr) => {
        resolve({ code: error ? error.code : 0, stdout, stderr });
      });
    });
  }

  before(async () => {
    assertLocalEmulators('FIREBASE_STORAGE_EMULATOR_HOST');
    storageEmulatorUrl = `http://${emulatorHost}`;
    workDirectory = await mkdtemp(join(tmpdir(), 'vifi-revoke-emulator-'));

    process.env.STORAGE_EMULATOR_HOST = storageEmulatorUrl;
    try {
      const bucket = new Storage({ projectId: 'demo-vifi', retryOptions: { autoRetry: false } }).bucket(BUCKET);
      const seed = [
        ['imagess/a.jpg', 'image/jpeg', 'token-a'],
        ['imagess/b.jpg', 'image/jpeg', 'token-b1,token-b2'],
        ['pdfs/c.pdf', 'application/pdf', 'token-c'],
        ['other/d.txt', 'text/plain', 'token-d'],
      ];
      for (const [name, contentType, tokens] of seed) {
        await bucket.file(name).save(Buffer.from(`content of ${name}`), {
          resumable: false,
          metadata: { contentType, metadata: { firebaseStorageDownloadTokens: tokens } },
        });
      }
    } finally {
      delete process.env.STORAGE_EMULATOR_HOST;
    }
  });

  after(async () => {
    if (workDirectory) {
      await rm(workDirectory, { recursive: true, force: true });
    }
  });

  test('backup records every token under the default prefixes', async () => {
    const result = await cli('backup', '--out', 'tokens.json');
    assert.equal(result.code, 0, result.stderr);
    const entries = JSON.parse(await readFile(join(workDirectory, 'tokens.json'), 'utf8'));
    assert.deepEqual(entries.map((entry) => [entry.name, [...entry.tokens].sort()]), [
      ['imagess/a.jpg', ['token-a']],
      ['imagess/b.jpg', ['token-b1', 'token-b2']],
      ['pdfs/c.pdf', ['token-c']],
    ]);
    assert.ok(entries.every((entry) => /^[0-9]+$/.test(entry.generation)));
  });

  test('revoke dry run plans every object with tokens and changes nothing', async () => {
    const result = await cli('revoke', '--backup', 'tokens.json');
    assert.equal(result.code, 0, result.stderr);
    assert.match(result.stdout, /Scanned 3 object\(s\): 3 with download tokens, 0 without/);
    assert.match(result.stdout, /would remove firebaseStorageDownloadTokens from 3 object\(s\)/);

    const second = await cli('revoke', '--backup', 'tokens.json');
    assert.match(second.stdout, /3 with download tokens/);
  });

  test('revoke --apply is refused without a backup', async () => {
    const result = await cli('revoke', '--backup', 'missing.json', '--apply');
    assert.equal(result.code, 2);
    assert.match(result.stderr, /backup file does not exist/);
  });
});

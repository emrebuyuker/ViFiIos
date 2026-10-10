// Adversarial checks of scripts/revoke-download-tokens.mjs against the in-memory Cloud Storage fake
// (tests/fake-gcs-server.mjs). Never touches the real bucket: STORAGE_EMULATOR_HOST points at the fake
// and the bucket is a demo name.

import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { mkdir, mkdtemp, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { after, before, describe, test } from 'node:test';
import { startFakeGcs } from './fake-gcs-server.mjs';

const SCRIPT = fileURLToPath(new URL('../scripts/revoke-download-tokens.mjs', import.meta.url));
const TEST_BUCKET = 'demo-vifi-adversarial-bucket';

describe('revoke-download-tokens backup file', () => {
  let fake;
  let workDirectory;

  function cli(...args) {
    const env = { ...process.env, STORAGE_EMULATOR_HOST: fake.url };
    delete env.GOOGLE_APPLICATION_CREDENTIALS;
    return new Promise((resolve) => {
      execFile(process.execPath, [SCRIPT, ...args, '--bucket', TEST_BUCKET], { env, cwd: workDirectory }, (error, stdout, stderr) => {
        resolve({ code: error ? error.code : 0, stdout, stderr });
      });
    });
  }

  before(async () => {
    fake = await startFakeGcs();
    workDirectory = await mkdtemp(join(tmpdir(), 'vifi-revoke-adversarial-'));
    fake.put(TEST_BUCKET, 'imagess/a.jpg', { tokens: ['secret-token-a'] });
  });

  after(async () => {
    await fake?.close();
    if (workDirectory) {
      await rm(workDirectory, { recursive: true, force: true });
    }
  });

  // The backup holds every live download token, i.e. a working public link to every archive file,
  // so neither other local accounts nor backup/sync agents may read it.
  test('backup file is readable only by its owner', async () => {
    const result = await cli('backup', '--out', 'backups/tokens.json');
    assert.equal(result.code, 0, result.stderr);
    const { mode } = await stat(join(workDirectory, 'backups/tokens.json'));
    assert.equal(mode & 0o077, 0, `backup file mode is ${(mode & 0o777).toString(8)}`);
  });

  test('backup refuses a path in a git work tree that git does not ignore', async () => {
    // A throwaway repository inside the temporary directory; never the project repository.
    const repository = join(workDirectory, 'repo');
    await mkdir(repository);
    await new Promise((resolve, reject) => {
      execFile('git', ['init', '--quiet', repository], (error) => (error ? reject(error) : resolve()));
    });
    await writeFile(join(repository, '.gitignore'), 'ignored/\n');

    const refused = await cli('backup', '--out', 'repo/backups/tokens.json');
    assert.equal(refused.code, 2, refused.stderr);
    assert.match(refused.stderr, /not git-ignored/);
    await assert.rejects(stat(join(repository, 'backups/tokens.json')), { code: 'ENOENT' });

    const accepted = await cli('backup', '--out', 'repo/ignored/tokens.json');
    assert.equal(accepted.code, 0, accepted.stderr);
  });
});

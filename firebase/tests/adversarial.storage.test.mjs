// Adversarial probes against storage.rules, run against the local Storage emulator (demo-vifi).
//
// Each test asserts the SECURE behaviour. A passing test is an attack the rules stop (kept as a
// regression guard). Tests marked `todo` are known platform limits or accepted design choices that
// rules cannot close; they keep running so a change in emulator/platform behaviour is visible.

import assert from 'node:assert/strict';
import { after, before, beforeEach, describe, test } from 'node:test';
import { assertFails } from '@firebase/rules-unit-testing';
import { Storage } from '@google-cloud/storage';
import { PROJECT_ID, assertLocalEmulators, contextFor, createStorageEnvironment, users } from './helpers.mjs';

const JPEG = { contentType: 'image/jpeg' };
const PDF = { contentType: 'application/pdf' };
const ARCHIVE_IMAGE = 'imagess/0b5b1c9e-7a51-4b8e-9f3a-333333333333.jpg';
const ALICE_PENDING = 'pending/alice/sub1/page-1.jpg';

const bytes = (size = 16, fill = 0xff) => new Uint8Array(size).fill(fill);

let env;

before(async () => {
  env = await createStorageEnvironment();
});

after(async () => {
  await env?.cleanup();
});

beforeEach(async () => {
  await env.clearStorage();
  await env.withSecurityRulesDisabled(async (context) => {
    await context.storage().ref(ARCHIVE_IMAGE).put(bytes(), JPEG);
    await context.storage().ref(ALICE_PENDING).put(bytes(), JPEG);
  });
});

const storage = (user) => contextFor(env, user).storage();
const upload = (user, path, data, metadata) => Promise.resolve(storage(user).ref(path).put(data, metadata));

/** Fetches a URL handed out by the emulator with NO credentials, like a stranger clicking a shared link. */
async function anonymousFetch(url) {
  assertLocalEmulators('FIREBASE_STORAGE_EMULATOR_HOST');
  const parsed = new URL(url);
  assert.equal(parsed.host, process.env.FIREBASE_STORAGE_EMULATOR_HOST, `refusing to fetch non-emulator URL ${url}`);
  const response = await fetch(url);
  return { status: response.status, headers: response.headers };
}

/** Cloud Storage JSON API client bound to the local emulator (Admin-SDK style access, never production). */
function gcsBucket() {
  assertLocalEmulators('FIREBASE_STORAGE_EMULATOR_HOST');
  const previous = process.env.STORAGE_EMULATOR_HOST;
  process.env.STORAGE_EMULATOR_HOST = `http://${process.env.FIREBASE_STORAGE_EMULATOR_HOST}`;
  try {
    return new Storage({ projectId: PROJECT_ID, retryOptions: { autoRetry: false } }).bucket(PROJECT_ID);
  } finally {
    if (previous === undefined) {
      delete process.env.STORAGE_EMULATOR_HOST;
    } else {
      process.env.STORAGE_EMULATOR_HOST = previous;
    }
  }
}

// Rules cannot stop Firebase Storage from attaching download tokens (documented in storage.rules).
const TOKEN_LIMIT = 'platform limit: Firebase Storage mints download tokens on upload and on Firebase API reads';

describe('download tokens bypass the rules', () => {
  // LIMIT: every client upload is given a firebaseStorageDownloadTokens token and the uploader can
  // read it back (upload response / getMetadata / getDownloadURL). The resulting ?token= link is
  // public, needs no ID token and no App Check, so any +90 user gets free anonymous hosting of any
  // bytes (declared image/jpeg or application/pdf, up to 15 MiB, unlimited count) on the project bucket.
  test('a pending upload does not give the uploader a public link', { todo: TOKEN_LIMIT }, async () => {
    await upload(users.alice, 'pending/alice/subX/invoice.pdf', bytes(64, 0x25), PDF);
    const url = await storage(users.alice).ref('pending/alice/subX/invoice.pdf').getDownloadURL();
    const response = await anonymousFetch(url);
    assert.notEqual(response.status, 200, `stranger downloaded the pending upload anonymously via ${url}`);
  });

  // LIMIT (same root cause, archive side): after `revoke-download-tokens.mjs revoke --apply`, any
  // +90 user can still mint/obtain a fresh public link for any archive file.
  test('a +90 reader cannot turn an archive file into a public link', { todo: TOKEN_LIMIT }, async () => {
    const url = await storage(users.alice).ref(ARCHIVE_IMAGE).getDownloadURL();
    const response = await anonymousFetch(url);
    assert.notEqual(response.status, 200, `stranger downloaded the archive file anonymously via ${url}`);
  });

  test('a revoked (token-less) archive file stays token-less after an authenticated read', { todo: TOKEN_LIMIT }, async () => {
    const name = 'imagess/revoked-0000-0000.jpg';
    const file = gcsBucket().file(name);
    await file.save(Buffer.from('jpeg bytes'), { resumable: false, metadata: { contentType: 'image/jpeg' } });
    const [before] = await file.getMetadata();
    assert.equal(before.metadata?.firebaseStorageDownloadTokens, undefined, 'seed must start without a token (as after revocation)');

    // What the new app does on every download: an authenticated Firebase Storage read.
    await storage(users.alice).ref(name).getMetadata();

    const [afterRead] = await file.getMetadata();
    assert.equal(afterRead.metadata?.firebaseStorageDownloadTokens, undefined,
      `an authenticated read re-minted a public download token: ${afterRead.metadata?.firebaseStorageDownloadTokens}`);
  });
});

describe('owner-controlled upload metadata is not constrained', () => {
  // storage.rules now rejects owner uploads with Content-Disposition, Content-Encoding or custom
  // metadata. A client-chosen firebaseStorageDownloadTokens value is turned into the object's token
  // by the emulator before the rules see the custom metadata, so rules cannot reject it there; the
  // uploader gets a token either way (see TOKEN_LIMIT).
  test('uploader cannot choose the download token', { todo: TOKEN_LIMIT }, async () => {
    const path = 'pending/alice/subY/page.jpg';
    let accepted = true;
    try {
      await upload(users.alice, path, bytes(), { ...JPEG, customMetadata: { firebaseStorageDownloadTokens: 'attacker-chosen-token' } });
    } catch {
      accepted = false;
    }
    if (accepted) {
      const host = process.env.FIREBASE_STORAGE_EMULATOR_HOST;
      const response = await anonymousFetch(`http://${host}/v0/b/${PROJECT_ID}/o/${encodeURIComponent(path)}?alt=media&token=attacker-chosen-token`);
      assert.notEqual(response.status, 200, 'the attacker-chosen token works as a public link');
    }
    assert.equal(accepted, false, 'upload with custom firebaseStorageDownloadTokens metadata was accepted');
  });

  test('uploader cannot set Content-Disposition (served filename) or Content-Encoding', async () => {
    await assertFails(upload(users.alice, 'pending/alice/subZ/a.pdf', bytes(), { ...PDF, contentDisposition: 'attachment; filename="Fatura.exe"' }));
    await assertFails(upload(users.alice, 'pending/alice/subZ/b.pdf', bytes(), { ...PDF, contentEncoding: 'gzip' }));
  });

  test('uploader cannot attach arbitrary custom metadata', async () => {
    await assertFails(upload(users.alice, 'pending/alice/subZ/c.jpg', bytes(), { ...JPEG, customMetadata: { approved: 'true', x: 'y'.repeat(4000) } }));
  });
});

describe('owner cannot replace a submitted file', () => {
  // ACCEPTED: "update never for owners" is bypassed by delete + create on the same path, so the bytes an
  // admin reviewed can be swapped before the approval copies them (no rule ties files to status).
  // Owners may delete their pending files (spec), and rules cannot see the RTDB status. Approval
  // tooling must pin the reviewed generation instead (documented in storage.rules).
  test('delete followed by re-upload at the same path is denied', { todo: 'accepted: owner delete is allowed by the spec' }, async () => {
    await storage(users.alice).ref(ALICE_PENDING).delete();
    await assertFails(upload(users.alice, ALICE_PENDING, bytes(32, 0x00), JPEG));
  });
});

describe('probes the rules already stop', () => {
  test('crafted phone_number claims cannot read the archive', async () => {
    for (const token of [{ phone_number: '+905551112233\n' }, { phone_number: ['+905551112233'] }, { phone_number: 905551112233 }, { admin: 1 }]) {
      await assertFails(env.authenticatedContext('crafted', token).storage().ref(ARCHIVE_IMAGE).getMetadata());
    }
  });

  test('owner cannot list own pending folders', async () => {
    await assertFails(storage(users.alice).ref('pending/alice/sub1').listAll());
    await assertFails(storage(users.alice).ref('pending').listAll());
  });

  test('unauthenticated raw Firebase API calls are denied', async () => {
    const host = process.env.FIREBASE_STORAGE_EMULATOR_HOST;
    for (const path of [ARCHIVE_IMAGE, ALICE_PENDING]) {
      const response = await anonymousFetch(`http://${host}/v0/b/${PROJECT_ID}/o/${encodeURIComponent(path)}?alt=media`);
      assert.equal(response.status, 403, `${path} served without auth`);
    }
    const list = await anonymousFetch(`http://${host}/v0/b/${PROJECT_ID}/o?prefix=imagess%2F`);
    assert.equal(list.status, 403, 'listing served without auth');
  });

  test('owner upload with mixed-case or parameterised content types is denied', async () => {
    for (const contentType of ['IMAGE/JPEG', 'application/pdf ', 'image/jpeg;x=y', 'text/html']) {
      await assertFails(upload(users.alice, 'pending/alice/subW/x', bytes(), { contentType }));
    }
  });
});

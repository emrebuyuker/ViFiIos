// Cloud Storage security rules tests (storage.rules), run against the local emulator.

import { after, before, beforeEach, describe, test } from 'node:test';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import { contextFor, createStorageEnvironment, users } from './helpers.mjs';

const MiB = 1024 * 1024;
const JPEG = { contentType: 'image/jpeg' };
const PDF = { contentType: 'application/pdf' };

const ARCHIVE_IMAGE = 'imagess/0b5b1c9e-7a51-4b8e-9f3a-111111111111.jpg';
const ARCHIVE_PDF = 'pdfs/7d1e2f30-0c4b-4c41-8a7e-222222222222.pdf';
const ALICE_PENDING = 'pending/alice/sub1/page-1.jpg';
const BOB_PENDING = 'pending/bob/sub2/page-1.jpg';
const OTHER_PATH = 'other/random.txt';

const bytes = (size = 16) => new Uint8Array(size).fill(0xff);

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
    const storage = context.storage();
    await storage.ref(ARCHIVE_IMAGE).put(bytes(), JPEG);
    await storage.ref(ARCHIVE_PDF).put(bytes(), PDF);
    await storage.ref(ALICE_PENDING).put(bytes(), JPEG);
    await storage.ref(BOB_PENDING).put(bytes(), JPEG);
    await storage.ref(OTHER_PATH).put(bytes(), { contentType: 'text/plain' });
  });
});

const storage = (user) => contextFor(env, user).storage();
/** `put` returns an UploadTask; adopt it as a plain promise for the assertion helpers. */
const upload = (user, path, data, metadata) => Promise.resolve(storage(user).ref(path).put(data, metadata));

describe('unauthenticated', () => {
  test('cannot read anything', async () => {
    for (const path of [ARCHIVE_IMAGE, ARCHIVE_PDF, ALICE_PENDING, OTHER_PATH]) {
      await assertFails(storage(null).ref(path).getMetadata());
    }
    await assertFails(storage(null).ref(ARCHIVE_IMAGE).getDownloadURL());
  });

  test('cannot list or write anything', async () => {
    await assertFails(storage(null).ref('imagess').listAll());
    await assertFails(upload(null, 'imagess/new.jpg', bytes(), JPEG));
    await assertFails(upload(null, 'pending/alice/sub9/page-1.jpg', bytes(), JPEG));
    await assertFails(storage(null).ref(ARCHIVE_IMAGE).delete());
  });
});

describe('archive (imagess/, pdfs/)', () => {
  test('Turkish phone user can read single files', async () => {
    await assertSucceeds(storage(users.alice).ref(ARCHIVE_IMAGE).getMetadata());
    await assertSucceeds(storage(users.alice).ref(ARCHIVE_PDF).getMetadata());
    await assertSucceeds(storage(users.alice).ref(ARCHIVE_IMAGE).getDownloadURL());
  });

  for (const [label, user] of Object.entries({
    'non-TR phone (+1)': users.usPhone,
    'email-only token': users.emailOnly,
    '+90 with 9 digits': users.shortTrPhone,
    '+90 with 11 digits': users.longTrPhone,
  })) {
    test(`${label} cannot read`, async () => {
      await assertFails(storage(user).ref(ARCHIVE_IMAGE).getMetadata());
      await assertFails(storage(user).ref(ARCHIVE_PDF).getMetadata());
    });
  }

  test('nobody can list', async () => {
    for (const user of [users.alice, users.admin]) {
      await assertFails(storage(user).ref('imagess').listAll());
      await assertFails(storage(user).ref('pdfs').list({ maxResults: 10 }));
      await assertFails(storage(user).ref().listAll());
    }
  });

  test('Turkish phone user cannot write', async () => {
    await assertFails(upload(users.alice, 'imagess/new.jpg', bytes(), JPEG));
    await assertFails(upload(users.alice, 'pdfs/new.pdf', bytes(), PDF));
    await assertFails(upload(users.alice, ARCHIVE_IMAGE, bytes(), JPEG));
    await assertFails(storage(users.alice).ref(ARCHIVE_IMAGE).updateMetadata({ customMetadata: { x: 'y' } }));
    await assertFails(storage(users.alice).ref(ARCHIVE_PDF).delete());
  });

  test('a string "true" admin claim is not an admin', async () => {
    await assertFails(upload(users.fakeAdmin, 'imagess/new.jpg', bytes(), JPEG));
  });

  test('admin can read and write', async () => {
    await assertSucceeds(storage(users.admin).ref(ARCHIVE_IMAGE).getMetadata());
    await assertSucceeds(upload(users.admin, 'imagess/new.jpg', bytes(), JPEG));
    await assertSucceeds(upload(users.admin, 'pdfs/new.pdf', bytes(), PDF));
    await assertSucceeds(upload(users.admin, ARCHIVE_IMAGE, bytes(32), JPEG));
    await assertSucceeds(storage(users.admin).ref(ARCHIVE_PDF).updateMetadata({ cacheControl: 'private, max-age=3600' }));
    await assertSucceeds(storage(users.admin).ref(ARCHIVE_PDF).delete());
  });
});

describe('pending/{uid}/{submissionId}/', () => {
  test('owner can upload a JPEG and a PDF', async () => {
    await assertSucceeds(upload(users.alice, 'pending/alice/sub9/page-1.jpg', bytes(), JPEG));
    await assertSucceeds(upload(users.alice, 'pending/alice/sub9/exam.pdf', bytes(), PDF));
  });

  test('owner can upload exactly 15 MiB', async () => {
    await assertSucceeds(upload(users.alice, 'pending/alice/sub9/big.pdf', bytes(15 * MiB), PDF));
  });

  test('wrong content types are rejected', async () => {
    for (const contentType of ['image/png', 'image/heic', 'text/plain', 'application/octet-stream', 'image/jpeg; charset=utf-8']) {
      await assertFails(upload(users.alice, 'pending/alice/sub9/file', bytes(), { contentType }));
    }
  });

  test('empty and oversized files are rejected', async () => {
    await assertFails(upload(users.alice, 'pending/alice/sub9/empty.jpg', bytes(0), JPEG));
    await assertFails(upload(users.alice, 'pending/alice/sub9/huge.pdf', bytes(15 * MiB + 1), PDF));
  });

  test('cannot upload into another user\'s folder', async () => {
    await assertFails(upload(users.alice, 'pending/bob/sub9/page-1.jpg', bytes(), JPEG));
  });

  test('users without a Turkish phone number cannot upload into their own folder', async () => {
    await assertFails(upload(users.usPhone, `pending/${users.usPhone.uid}/sub9/page-1.jpg`, bytes(), JPEG));
    await assertFails(upload(users.emailOnly, `pending/${users.emailOnly.uid}/sub9/page-1.jpg`, bytes(), JPEG));
  });

  test('uploads outside the {uid}/{submissionId}/{file} shape are rejected', async () => {
    await assertFails(upload(users.alice, 'pending/alice/page-1.jpg', bytes(), JPEG));
    await assertFails(upload(users.alice, 'pending/alice/sub9/nested/page-1.jpg', bytes(), JPEG));
  });

  test('owner can read own files but not other users\' files', async () => {
    await assertSucceeds(storage(users.alice).ref(ALICE_PENDING).getMetadata());
    await assertFails(storage(users.alice).ref(BOB_PENDING).getMetadata());
    await assertFails(storage(users.alice).ref('pending/alice').listAll());
  });

  test('admin can read and delete any pending file', async () => {
    await assertSucceeds(storage(users.admin).ref(BOB_PENDING).getMetadata());
    await assertSucceeds(storage(users.admin).ref(BOB_PENDING).delete());
  });

  test('owner can delete own files, others cannot', async () => {
    await assertFails(storage(users.bob).ref(ALICE_PENDING).delete());
    await assertSucceeds(storage(users.alice).ref(ALICE_PENDING).delete());
  });

  test('owner cannot overwrite or update an uploaded file', async () => {
    await assertFails(upload(users.alice, ALICE_PENDING, bytes(32), JPEG));
    await assertFails(storage(users.alice).ref(ALICE_PENDING).updateMetadata({ contentType: 'application/pdf' }));
  });
});

describe('any other path', () => {
  test('is denied for everyone, admins included', async () => {
    for (const user of [users.alice, users.admin]) {
      await assertFails(storage(user).ref(OTHER_PATH).getMetadata());
      await assertFails(upload(user, 'other/new.jpg', bytes(), JPEG));
      await assertFails(upload(user, 'imagess/sub/nested.jpg', bytes(), JPEG));
      await assertFails(storage(user).ref(OTHER_PATH).delete());
    }
  });
});

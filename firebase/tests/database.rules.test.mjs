// Realtime Database security rules tests (database.rules.json), run against the local emulator.

import { after, before, beforeEach, describe, test } from 'node:test';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import { SERVER_TIMESTAMP, contextFor, createDatabaseEnvironment, users } from './helpers.mjs';

const DEEP_EXAM_PATH = 'Universitiess/ODTU/Muhendislik/Bilgisayar/Algoritmalar/Vize 2019/JPG/-NabcPushId';
const JUNK_PATHS = ['poc', '2DfjkeJxHJTkdhz5VNVwFJzAeuD', 'Announcements'];

/** A submission that satisfies every validation rule for `uid`/`submissionId`. */
function validSubmission(uid, submissionId, overrides = {}) {
  return {
    university: 'Orta Doğu Teknik Üniversitesi',
    faculty: 'Mühendislik Fakültesi',
    department: 'Bilgisayar Mühendisliği',
    lesson: 'CENG 140',
    exam: 'Vize 2019',
    kind: 'JPG',
    status: 'pending',
    createdAt: SERVER_TIMESTAMP,
    files: { 0: { storagePath: `pending/${uid}/${submissionId}/page-1.jpg` } },
    ...overrides,
  };
}

const seed = {
  Universitiess: {
    ODTU: {
      uniname: 'uniname',
      Muhendislik: {
        fakname: 'fakname',
        Bilgisayar: {
          bolname: 'bolname',
          Algoritmalar: {
            lessonname: 'lessonname',
            'Vize 2019': {
              imagename: 'imagename',
              JPG: {
                '-NabcPushId': {
                  downloadURL: 'https://firebasestorage.googleapis.com/v0/b/demo-vifi.appspot.com/o/imagess%2Fa.jpg?alt=media&token=t',
                },
              },
            },
          },
        },
      },
    },
  },
  poc: 'poc',
  '2DfjkeJxHJTkdhz5VNVwFJzAeuD': { anything: 1 },
  Announcements: { hello: 'world' },
  config: {
    appUpdate: {
      ios: { minimumVersion: '3.0.0', latestVersion: '3.0.0', storeURL: 'https://apps.apple.com/app/id1', message: 'Güncelle' },
    },
  },
  pendingExams: {
    alice: { existing: { ...validSubmission('alice', 'existing'), createdAt: 1_700_000_000_000 } },
    bob: { theirs: { ...validSubmission('bob', 'theirs'), createdAt: 1_700_000_000_000 } },
  },
};

let env;

before(async () => {
  env = await createDatabaseEnvironment();
});

after(async () => {
  await env?.cleanup();
});

beforeEach(async () => {
  await env.clearDatabase();
  await env.withSecurityRulesDisabled(async (context) => {
    await context.database().ref().set(seed);
  });
});

const db = (user) => contextFor(env, user).database();

/** `assertFails` that names the failing case when one of many looped variants is unexpectedly allowed. */
async function assertDenied(operation, label) {
  try {
    await assertFails(operation);
  } catch (error) {
    error.message = `${label}: ${error.message}`;
    throw error;
  }
}

describe('unauthenticated', () => {
  const paths = ['', 'Universitiess', 'Universitiess/ODTU', DEEP_EXAM_PATH, `${DEEP_EXAM_PATH}/downloadURL`, ...JUNK_PATHS,
    'pendingExams', 'pendingExams/alice', 'pendingExams/alice/existing'];

  for (const path of paths) {
    test(`cannot read /${path}`, async () => {
      // `ref()` without an argument is the root; `ref('')` is rejected by the SDK.
      await assertFails(db(null).ref(path || undefined).get());
    });
  }

  test('cannot write anywhere', async () => {
    await assertFails(db(null).ref().set({ hacked: true }));
    await assertFails(db(null).ref('Universitiess/X').set({ uniname: 'X' }));
    await assertFails(db(null).ref(`${DEEP_EXAM_PATH}/downloadURL`).set('https://evil.example'));
    await assertFails(db(null).ref('Universitiess').remove());
    await assertFails(db(null).ref('poc').set('again'));
    await assertFails(db(null).ref('newJunk').set('x'));
    await assertFails(db(null).ref('pendingExams/alice/new').set(validSubmission('alice', 'new')));
  });
});

describe('Turkish phone user', () => {
  test('can read the archive, deep nodes and leaves', async () => {
    await assertSucceeds(db(users.alice).ref('Universitiess').get());
    await assertSucceeds(db(users.alice).ref('Universitiess/ODTU/Muhendislik').get());
    await assertSucceeds(db(users.alice).ref(DEEP_EXAM_PATH).get());
    await assertSucceeds(db(users.alice).ref(`${DEEP_EXAM_PATH}/downloadURL`).get());
  });

  test('cannot read the root or junk nodes', async () => {
    await assertFails(db(users.alice).ref().get());
    for (const path of JUNK_PATHS) {
      await assertFails(db(users.alice).ref(path).get());
    }
  });

  test('cannot read /pendingExams or other users\' submissions', async () => {
    await assertFails(db(users.alice).ref('pendingExams').get());
    await assertFails(db(users.alice).ref('pendingExams/bob').get());
    await assertFails(db(users.alice).ref('pendingExams/bob/theirs').get());
  });

  test('can read own submissions', async () => {
    await assertSucceeds(db(users.alice).ref('pendingExams/alice').get());
    await assertSucceeds(db(users.alice).ref('pendingExams/alice/existing').get());
  });

  test('cannot write the archive (set / update / remove)', async () => {
    const user = db(users.alice);
    await assertFails(user.ref('Universitiess').set({ X: { uniname: 'X' } }));
    await assertFails(user.ref('Universitiess/ODTU2').set({ uniname: 'ODTU2' }));
    await assertFails(user.ref('Universitiess/ODTU').update({ uniname: 'changed' }));
    await assertFails(user.ref(`${DEEP_EXAM_PATH}/downloadURL`).set('https://evil.example'));
    await assertFails(user.ref(DEEP_EXAM_PATH).remove());
    await assertFails(user.ref('Universitiess').remove());
  });

  test('cannot write the root or junk nodes', async () => {
    await assertFails(db(users.alice).ref().update({ newJunk: 'x' }));
    await assertFails(db(users.alice).ref('poc').set('x'));
    await assertFails(db(users.alice).ref('poc').remove());
  });
});

describe('users without a Turkish phone number', () => {
  const personas = {
    'non-TR phone (+1)': users.usPhone,
    'email-only token': users.emailOnly,
    '+90 with 9 digits': users.shortTrPhone,
    '+90 with 11 digits': users.longTrPhone,
  };

  for (const [label, user] of Object.entries(personas)) {
    test(`${label} cannot read the archive or own pending node`, async () => {
      await assertFails(db(user).ref('Universitiess').get());
      await assertFails(db(user).ref(DEEP_EXAM_PATH).get());
      await assertFails(db(user).ref(`pendingExams/${user.uid}`).get());
    });

    test(`${label} cannot submit`, async () => {
      await assertFails(db(user).ref(`pendingExams/${user.uid}/s1`).set(validSubmission(user.uid, 's1')));
    });
  }

  test('a string "true" admin claim is not an admin', async () => {
    await assertFails(db(users.fakeAdmin).ref('Universitiess/X').set({ uniname: 'X' }));
    await assertFails(db(users.fakeAdmin).ref('pendingExams').get());
  });
});

describe('admin', () => {
  test('can read and write the archive', async () => {
    const admin = db(users.admin);
    await assertSucceeds(admin.ref('Universitiess').get());
    await assertSucceeds(admin.ref('Universitiess/ITU').set({ uniname: 'uniname' }));
    await assertSucceeds(admin.ref('Universitiess/ODTU').update({ uniname: 'renamed' }));
    await assertSucceeds(admin.ref(`${DEEP_EXAM_PATH}/downloadURL`).set('https://example.invalid/new'));
    await assertSucceeds(admin.ref(DEEP_EXAM_PATH).remove());
  });

  test('still cannot read the root or junk nodes', async () => {
    await assertFails(db(users.admin).ref().get());
    await assertFails(db(users.admin).ref('poc').get());
    await assertFails(db(users.admin).ref('poc').set('x'));
  });

  test('can read every submission', async () => {
    await assertSucceeds(db(users.admin).ref('pendingExams').get());
    await assertSucceeds(db(users.admin).ref('pendingExams/bob/theirs').get());
  });

  test('can approve, reject and delete any submission', async () => {
    const admin = db(users.admin);
    await assertSucceeds(admin.ref('pendingExams/bob/theirs/status').set('approved'));
    await assertSucceeds(admin.ref('pendingExams/bob/theirs').update({ status: 'rejected' }));
    await assertSucceeds(admin.ref('pendingExams/bob/theirs').remove());
    await assertSucceeds(admin.ref('pendingExams/alice').remove());
  });

  test('can create a submission for any user', async () => {
    await assertSucceeds(db(users.admin).ref('pendingExams/bob/byAdmin').set(validSubmission('bob', 'byAdmin')));
  });

  test('is still bound by the submission schema', async () => {
    const admin = db(users.admin);
    await assertFails(admin.ref('pendingExams/bob/theirs/status').set('published'));
    await assertFails(admin.ref('pendingExams/bob/theirs/extra').set('x'));
    await assertFails(admin.ref('pendingExams/bob/theirs/kind').set('PNG'));
    await assertFails(admin.ref('pendingExams/bob').set('not an object'));
  });
});

describe('config (app update policy)', () => {
  const validPolicy = {
    minimumVersion: '3.1.0', latestVersion: '3.2.0', storeURL: 'https://apps.apple.com/app/id1', message: 'Güncelle',
  };

  test('anyone can read the policy, signed in or not', async () => {
    await assertSucceeds(db(null).ref('config').get());
    await assertSucceeds(db(null).ref('config/appUpdate/ios').get());
    await assertSucceeds(db(users.alice).ref('config/appUpdate/ios').get());
    await assertSucceeds(db(users.usPhone).ref('config/appUpdate/ios').get());
  });

  test('nobody but an admin can write it', async () => {
    await assertFails(db(null).ref('config/appUpdate/ios').set(validPolicy));
    await assertFails(db(users.alice).ref('config/appUpdate/ios').set(validPolicy));
    await assertFails(db(users.fakeAdmin).ref('config/appUpdate/ios').set(validPolicy));
    await assertFails(db(users.alice).ref('config/appUpdate/ios/minimumVersion').set('9.9.9'));
  });

  test('an admin can write a valid policy', async () => {
    const admin = db(users.admin);
    await assertSucceeds(admin.ref('config/appUpdate/ios').set(validPolicy));
    await assertSucceeds(admin.ref('config/appUpdate/ios/minimumVersion').set('3.3.0'));
  });

  test('the admin is still bound by the schema', async () => {
    const admin = db(users.admin);
    await assertFails(admin.ref('config/appUpdate/ios/minimumVersion').set('three'));
    await assertFails(admin.ref('config/appUpdate/ios/minimumVersion').set(3));
    await assertFails(admin.ref('config/appUpdate/ios/storeURL').set('http://insecure.example'));
    await assertFails(admin.ref('config/appUpdate/ios/extra').set('x'));
    await assertFails(admin.ref('config/appUpdate/ios/message').set('x'.repeat(301)));
  });
});

describe('pending submissions by their owner', () => {
  const create = (data, uid = 'alice', submissionId = 'new') => db(users.alice).ref(`pendingExams/${uid}/${submissionId}`).set(data);

  test('valid JPG submission is accepted', async () => {
    await assertSucceeds(create(validSubmission('alice', 'new')));
  });

  test('valid PDF submission with 50 files is accepted', async () => {
    const files = {};
    for (let index = 0; index < 50; index += 1) {
      files[index] = { storagePath: `pending/alice/new/file-${index}.pdf` };
    }
    await assertSucceeds(create(validSubmission('alice', 'new', { kind: 'PDF', files })));
  });

  test('names of exactly 120 characters are accepted', async () => {
    await assertSucceeds(create(validSubmission('alice', 'new', { lesson: 'ş'.repeat(120) })));
  });

  test('ordinary names with spaces, digits and punctuation are accepted', async () => {
    // Guards the character allowlist: Turkish letters, ASCII punctuation and typographic dashes/quotes pass.
    const names = [
      'ttt', 'nnn rrr', 'Türk Dili ve Edebiyatı (TDE) 2023-2024 Güz', 'MAT-101 Final, Bütünleme & Ara Sınav: A-B',
      'İTÜ Çağ Öğretim – Şişli', '‘Ara’ “Sınav” — Bölüm 2…',
    ];
    for (const [index, lesson] of names.entries()) {
      await assertSucceeds(create(validSubmission('alice', `ok${index}`, { lesson }), 'alice', `ok${index}`));
    }
  });

  test('createdAt must be the server time', async () => {
    await assertFails(create(validSubmission('alice', 'new', { createdAt: 1_700_000_000_000 })));
    await assertFails(create(validSubmission('alice', 'new', { createdAt: 'now' })));
  });

  test('status must be pending', async () => {
    await assertFails(create(validSubmission('alice', 'new', { status: 'approved' })));
    await assertFails(create(validSubmission('alice', 'new', { status: 'rejected' })));
    await assertFails(create(validSubmission('alice', 'new', { status: 'other' })));
  });

  test('every required field must be present', async () => {
    for (const field of ['university', 'faculty', 'department', 'lesson', 'exam', 'kind', 'status', 'createdAt', 'files']) {
      const data = validSubmission('alice', 'new');
      delete data[field];
      await assertDenied(create(data), `missing ${field} must be rejected`);
    }
  });

  test('extra fields are rejected at every level', async () => {
    await assertFails(create(validSubmission('alice', 'new', { approvedBy: 'alice' })));
    await assertFails(create(validSubmission('alice', 'new', {
      files: { 0: { storagePath: 'pending/alice/new/page-1.jpg', downloadURL: 'https://evil.example' } },
    })));
    await assertFails(create(validSubmission('alice', 'new', { files: { 0: { storagePath: 'pending/alice/new/page-1.jpg' }, extra: 'x' } })));
  });

  test('kind must be JPG or PDF', async () => {
    await assertFails(create(validSubmission('alice', 'new', { kind: 'PNG' })));
    await assertFails(create(validSubmission('alice', 'new', { kind: 'jpg' })));
    await assertFails(create(validSubmission('alice', 'new', { kind: 1 })));
  });

  test('names reject forbidden characters, blanks, non-strings and >120 characters', async () => {
    const badNames = [
      'CENG/140', 'Vize.2019', 'a#b', 'a$b', 'a[b', 'a]b', // Forbidden in RTDB keys, so the admin could not approve them.
      '', '   ', '\u00a0\u3000', '\u200b', // Empty or whitespace only.
      '\t\n', 'Vize\n2019', 'Vize\t2019', 'a\u007fb', 'Vize\u00852019', 'CENG\u202e041', 'a\u00adb', // Control and format characters.
      '\u1680', '\u2028', '\u202f', '\ufeff', // Other Unicode blanks.
      'Vize 😀', '東京大学', '€', // Outside the allowed character set.
      'x'.repeat(121), 42, true, { nested: 'x' },
    ];
    for (const name of badNames) {
      for (const field of ['university', 'faculty', 'department', 'lesson', 'exam']) {
        await assertDenied(create(validSubmission('alice', 'new', { [field]: name })), `${field}=${JSON.stringify(name)} must be rejected`);
      }
    }
  });

  test('files must be a non-empty object of { storagePath }', async () => {
    await assertFails(create(validSubmission('alice', 'new', { files: {} })));
    await assertFails(create(validSubmission('alice', 'new', { files: 'pending/alice/new/page-1.jpg' })));
    await assertFails(create(validSubmission('alice', 'new', { files: { 0: 'pending/alice/new/page-1.jpg' } })));
    await assertFails(create(validSubmission('alice', 'new', { files: { 0: { storagePath: 7 } } })));
  });

  test('file keys are limited to "0".."49"', async () => {
    for (const key of ['50', '99', '07', '-1', 'a']) {
      await assertDenied(create(validSubmission('alice', 'new', { files: { [key]: { storagePath: 'pending/alice/new/page.jpg' } } })),
        `file key ${key} must be rejected`);
    }
  });

  test('storagePath must stay inside the submission\'s own pending folder', async () => {
    const badPaths = [
      'pending/bob/new/page-1.jpg',
      'pending/alice/other/page-1.jpg',
      'pending/alice/new/',
      'pending/alice/new/nested/page-1.jpg',
      'imagess/0b5b1c9e.jpg',
      'pending/alice/newer/page-1.jpg',
      `pending/alice/new/${'p'.repeat(290)}.jpg`,
    ];
    for (const storagePath of badPaths) {
      await assertDenied(create(validSubmission('alice', 'new', { files: { 0: { storagePath } } })), `${storagePath} must be rejected`);
    }
  });

  test('cannot create under another user\'s uid', async () => {
    await assertFails(create(validSubmission('bob', 'new'), 'bob'));
  });

  test('cannot overwrite an existing submission', async () => {
    await assertFails(create(validSubmission('alice', 'existing'), 'alice', 'existing'));
  });

  test('cannot update an own submission', async () => {
    const ref = db(users.alice).ref('pendingExams/alice/existing');
    await assertFails(ref.update({ exam: 'Final 2019' }));
    await assertFails(ref.child('status').set('approved'));
    await assertFails(ref.child('files/1').set({ storagePath: 'pending/alice/existing/page-2.jpg' }));
    await assertFails(ref.child('files').remove());
  });

  test('cannot replace the whole pending node of the user', async () => {
    await assertFails(db(users.alice).ref('pendingExams/alice').set({ new: validSubmission('alice', 'new') }));
  });

  test('can delete an own submission while it is pending', async () => {
    await assertSucceeds(db(users.alice).ref('pendingExams/alice/existing').remove());
  });

  test('cannot delete an own submission after the admin approved or rejected it', async () => {
    for (const status of ['approved', 'rejected']) {
      await env.withSecurityRulesDisabled(async (context) => {
        await context.database().ref('pendingExams/alice/existing/status').set(status);
      });
      await assertDenied(db(users.alice).ref('pendingExams/alice/existing').remove(), `delete after ${status} must be rejected`);
    }
  });

  test('cannot delete another user\'s submission', async () => {
    await assertFails(db(users.alice).ref('pendingExams/bob/theirs').remove());
  });
});

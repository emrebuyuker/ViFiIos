// Adversarial probes against database.rules.json, run against the local RTDB emulator (demo-vifi).
//
// Each test asserts the SECURE behaviour. A failing test here is a confirmed hole or spec gap;
// a passing test is an attack that the rules already stop (kept as a regression guard).

import assert from 'node:assert/strict';
import { after, before, beforeEach, describe, test } from 'node:test';
import { assertFails } from '@firebase/rules-unit-testing';
import { PROJECT_ID, SERVER_TIMESTAMP, assertLocalEmulators, contextFor, createDatabaseEnvironment, users } from './helpers.mjs';

function validSubmission(uid, submissionId, overrides = {}) {
  return {
    university: 'ODTU',
    faculty: 'Muhendislik',
    department: 'Bilgisayar',
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
  Universitiess: { ODTU: { uniname: 'uniname', Muhendislik: { fakname: 'fakname' } } },
  poc: 'poc',
  Announcements: { hello: 'world' },
  pendingExams: {
    alice: {
      existing: { ...validSubmission('alice', 'existing'), createdAt: 1_700_000_000_000 },
      approved: { ...validSubmission('alice', 'approved'), status: 'approved', createdAt: 1_700_000_000_000 },
    },
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

async function assertDenied(operation, label) {
  try {
    await assertFails(operation);
  } catch (error) {
    error.message = `${label}: ${error.message}`;
    throw error;
  }
}

/** Raw REST call to the local RTDB emulator, exactly what an attacker with curl would send. */
async function rest(method, path, { query = '', body } = {}) {
  assertLocalEmulators('FIREBASE_DATABASE_EMULATOR_HOST');
  const separator = query ? '&' : '';
  const url = `http://${process.env.FIREBASE_DATABASE_EMULATOR_HOST}${path}.json?${query}${separator}ns=${PROJECT_ID}`;
  const response = await fetch(url, {
    method,
    headers: body === undefined ? {} : { 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: response.status, text: await response.text() };
}

describe('unauthenticated REST API (curl with the public config)', () => {
  const reads = [
    ['/', ''],
    ['/', 'shallow=true'],
    ['/', 'orderBy="$key"&limitToFirst=1'],
    ['/Universitiess', 'shallow=true'],
    ['/Universitiess/ODTU', ''],
    ['/Universitiess', 'orderBy="$key"&equalTo="ODTU"'],
    ['/poc', ''],
    ['/Announcements', 'shallow=true'],
    ['/pendingExams', 'shallow=true'],
    ['/pendingExams/alice', ''],
  ];
  for (const [path, query] of reads) {
    test(`GET ${path}.json?${query} is denied`, async () => {
      const response = await rest('GET', path === '/' ? '/' : path, { query });
      assert.equal(response.status, 401, `expected 401, got ${response.status}: ${response.text.slice(0, 200)}`);
    });
  }

  for (const [method, path, body] of [
    ['PUT', '/poc', 'x'],
    ['PATCH', '/', { newJunk: 'x' }],
    ['POST', '/Universitiess', { uniname: 'x' }],
    ['DELETE', '/Announcements', undefined],
    ['PUT', '/pendingExams/alice/viaRest', validSubmission('alice', 'viaRest')],
  ]) {
    test(`${method} ${path}.json is denied`, async () => {
      const response = await rest(method, path, { body });
      assert.equal(response.status, 401, `expected 401, got ${response.status}: ${response.text.slice(0, 200)}`);
    });
  }
});

describe('owner write tricks on an existing submission', () => {
  test('cannot approve own submission through a multi-path update at the user node or root', async () => {
    await assertFails(db(users.alice).ref('pendingExams/alice').update({ 'existing/status': 'approved' }));
    await assertFails(db(users.alice).ref().update({ 'pendingExams/alice/existing/status': 'approved' }));
  });

  test('cannot approve own submission through a transaction', async () => {
    await assertFails(db(users.alice).ref('pendingExams/alice/existing/status').transaction(() => 'approved'));
  });

  test('cannot change priority of an existing submission', async () => {
    await assertFails(db(users.alice).ref('pendingExams/alice/existing').setPriority(1));
  });

  test('cannot delete an approved submission by removing the whole user node or via a null multi-path update', async () => {
    await assertFails(db(users.alice).ref('pendingExams/alice').remove());
    await assertFails(db(users.alice).ref('pendingExams/alice').update({ approved: null }));
    await assertFails(db(users.alice).ref().update({ 'pendingExams/alice/approved': null }));
  });

  test('cannot smuggle an archive write next to a valid create', async () => {
    await assertFails(db(users.alice).ref().update({
      'pendingExams/alice/combo': validSubmission('alice', 'combo'),
      'Universitiess/EVIL': { uniname: 'x' },
    }));
  });

  test('createdAt cannot be forged with a server increment', async () => {
    await assertFails(db(users.alice).ref('pendingExams/alice/inc').set(validSubmission('alice', 'inc', { createdAt: { '.sv': { increment: 1 } } })));
  });

  test('cannot read other users\' submissions via child paths', async () => {
    await assertFails(db(users.alice).ref('pendingExams/bob/theirs/status').get());
    await assertFails(db(users.alice).ref('pendingExams/bob/theirs/files').get());
  });
});

describe('crafted auth tokens', () => {
  const crafted = {
    'phone_number with trailing newline': { uid: 'nl', token: { phone_number: '+905551112233\n' } },
    'phone_number array': { uid: 'arr', token: { phone_number: ['+905551112233'] } },
    'phone_number number': { uid: 'num', token: { phone_number: 905551112233 } },
    'admin claim 1': { uid: 'one', token: { admin: 1 } },
    'admin claim "true" without phone': { uid: 'str', token: { admin: 'true' } },
  };
  for (const [label, user] of Object.entries(crafted)) {
    test(`${label} cannot read the archive`, async () => {
      await assertFails(db(user).ref('Universitiess').get());
    });
  }
});

// Formerly a gap: "must not be only whitespace" used a hand-written blank list. The RTDB rules lexer
// silently drops Unicode format characters (U+200B, U+FEFF, bidi controls) from the rule source and
// rejects U+2028/U+2029 inside literals, so such a list cannot be written; names now use an allowlist.
describe('names made only of Unicode whitespace', () => {
  const blanks = {
    'U+1680 OGHAM SPACE MARK': ' ',
    'U+0085 NEXT LINE (C1 control, White_Space)': '\u0085',
    'U+2028 LINE SEPARATOR': ' ',
    'U+2029 PARAGRAPH SEPARATOR': ' ',
    'U+202F NARROW NO-BREAK SPACE': ' ',
    'U+205F MEDIUM MATHEMATICAL SPACE': ' ',
    'space + U+202F + space': '   ',
  };
  for (const [label, name] of Object.entries(blanks)) {
    test(`${label} is rejected as a name`, async () => {
      await assertDenied(db(users.alice).ref('pendingExams/alice/blank').set(validSubmission('alice', 'blank', { lesson: name })),
        `lesson=${JSON.stringify(name)} must be rejected`);
    });
  }
});

// Formerly a hole: only C0 + DEL were rejected, so C1 controls and bidi overrides passed and an approved
// name (which becomes an /Universitiess key shown to every user) could render reversed/spoofed.
describe('names with C1 controls or bidi overrides', () => {
  const names = {
    'embedded U+0085 NEXT LINE': 'Vize\u00852019',
    'embedded U+009B CSI': 'Vize\u009b2019',
    'embedded U+202E RIGHT-TO-LEFT OVERRIDE': 'CENG‮041 lanif',
    'embedded U+2066 LEFT-TO-RIGHT ISOLATE': 'CENG⁦140',
  };
  for (const [label, name] of Object.entries(names)) {
    test(`${label} is rejected as a name`, async () => {
      await assertDenied(db(users.alice).ref('pendingExams/alice/ctl').set(validSubmission('alice', 'ctl', { exam: name })),
        `exam=${JSON.stringify(name)} must be rejected`);
    });
  }
});

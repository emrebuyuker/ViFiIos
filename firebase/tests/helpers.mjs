// Shared fixtures for the security rules tests.
//
// These tests only ever talk to the local Firebase emulators started by
// `npm test` (`firebase emulators:exec --project demo-vifi ...`). The `demo-` prefix makes the
// Firebase CLI refuse to reach any real project, and `assertLocalEmulators` double-checks it.

import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { initializeTestEnvironment } from '@firebase/rules-unit-testing';
import { setLogLevel } from 'firebase/app';

// Every denied operation would otherwise print a "permission_denied" SDK warning.
setLogLevel('error');

export const PROJECT_ID = 'demo-vifi';

/** Server-side timestamp placeholder (`ServerValue.TIMESTAMP`), resolved by the database as `now`. */
export const SERVER_TIMESTAMP = Object.freeze({ '.sv': 'timestamp' });

/** Signed-in personas. `tokenOptions` become claims of the emulator's mock ID token. */
export const users = Object.freeze({
  alice: { uid: 'alice', token: { phone_number: '+905551112233' } },
  bob: { uid: 'bob', token: { phone_number: '+905559998877' } },
  usPhone: { uid: 'carol', token: { phone_number: '+15551234567' } },
  emailOnly: { uid: 'dave', token: { email: 'dave@example.com', email_verified: true } },
  shortTrPhone: { uid: 'erin', token: { phone_number: '+90555111223' } },
  longTrPhone: { uid: 'frank', token: { phone_number: '+9055511122334' } },
  fakeAdmin: { uid: 'mallory', token: { phone_number: '+905550000000', admin: 'true' } },
  admin: { uid: 'admin-1', token: { admin: true } },
});

const rulesPath = (name) => fileURLToPath(new URL(`../${name}`, import.meta.url));

/** Fails fast if the emulator environment variables point anywhere but this machine. */
export function assertLocalEmulators(...names) {
  for (const name of names) {
    const host = process.env[name];
    if (!host || !/^(127\.0\.0\.1|localhost|\[::1\]|::1):\d+$/.test(host)) {
      throw new Error(`${name} must point to a local emulator (got ${JSON.stringify(host)}). Run the tests with \`npm test\`.`);
    }
  }
}

export async function createDatabaseEnvironment() {
  assertLocalEmulators('FIREBASE_DATABASE_EMULATOR_HOST');
  return initializeTestEnvironment({
    projectId: PROJECT_ID,
    database: { rules: await readFile(rulesPath('database.rules.json'), 'utf8') },
  });
}

export async function createStorageEnvironment() {
  assertLocalEmulators('FIREBASE_STORAGE_EMULATOR_HOST');
  return initializeTestEnvironment({
    projectId: PROJECT_ID,
    storage: { rules: await readFile(rulesPath('storage.rules'), 'utf8') },
  });
}

/** The context for one of `users`, or an unauthenticated one for `null`. */
export function contextFor(env, user) {
  return user ? env.authenticatedContext(user.uid, user.token) : env.unauthenticatedContext();
}

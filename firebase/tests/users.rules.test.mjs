// Security rules tests for the user profile node (users/<uid>/profile), run against the local emulator.

import { after, before, beforeEach, describe, test } from 'node:test';
import { assertFails, assertSucceeds } from '@firebase/rules-unit-testing';
import { SERVER_TIMESTAMP, contextFor, createDatabaseEnvironment, users } from './helpers.mjs';

/** A profile that satisfies every validation rule for `user` (its phone number must match the token). */
function validProfile(user, overrides = {}) {
  return {
    name: 'Ayşe',
    surname: 'Yılmaz',
    university: 'Boğaziçi Üniversitesi',
    universityId: 'bogazici-universitesi',
    universityIsCustom: false,
    faculty: 'Mühendislik Fakültesi',
    facultyId: 'muhendislik-fakultesi',
    facultyIsCustom: false,
    department: 'Bilgisayar Mühendisliği',
    departmentId: 'bilgisayar-muhendisligi',
    departmentIsCustom: false,
    gender: 'female',
    phoneNumber: user.token.phone_number,
    updatedAt: SERVER_TIMESTAMP,
    ...overrides,
  };
}

const seed = {
  users: {
    bob: {
      profile: {
        name: 'Mehmet',
        surname: 'Demir',
        university: 'Ege Üniversitesi',
        universityId: 'ege-universitesi',
        universityIsCustom: false,
        faculty: 'İktisadi ve İdari Bilimler Fakültesi',
        facultyId: 'iktisadi-ve-idari-bilimler-fakultesi',
        facultyIsCustom: false,
        department: 'İşletme',
        departmentId: 'isletme',
        departmentIsCustom: false,
        gender: 'male',
        phoneNumber: users.bob.token.phone_number,
        updatedAt: 1_700_000_000_000,
      },
    },
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
const profileRef = (user, uid = user?.uid) => db(user).ref(`users/${uid}/profile`);

/** `assertFails` that names the failing variant when a looped case is unexpectedly allowed. */
async function assertDenied(operation, label) {
  try {
    await assertFails(operation);
  } catch (error) {
    error.message = `${label}: ${error.message}`;
    throw error;
  }
}

describe('users/<uid>/profile — owner', () => {
  test('a +90 owner can write a valid profile', async () => {
    await assertSucceeds(profileRef(users.alice).set(validProfile(users.alice)));
  });

  test('a +90 owner can read their own profile (even when absent)', async () => {
    await assertSucceeds(profileRef(users.alice).get());
  });

  test('a +90 owner can read their own stored profile', async () => {
    await assertSucceeds(profileRef(users.bob).get());
  });

  test('a +90 owner can update their existing profile', async () => {
    await assertSucceeds(profileRef(users.bob).set(validProfile(users.bob, { name: 'Ali' })));
  });
});

describe('users/<uid>/profile — other users and strangers', () => {
  test('another user cannot read it', async () => {
    await assertFails(db(users.alice).ref('users/bob/profile').get());
  });

  test('another user cannot write it', async () => {
    await assertFails(db(users.alice).ref('users/bob/profile').set(validProfile(users.bob)));
  });

  test('an unauthenticated client cannot read or write it', async () => {
    await assertDenied(db(null).ref('users/bob/profile').get(), 'anon read');
    await assertDenied(db(null).ref('users/bob/profile').set(validProfile(users.bob)), 'anon write');
  });

  test('a non-+90 phone cannot write its own profile', async () => {
    await assertFails(profileRef(users.usPhone).set(validProfile(users.usPhone)));
  });

  test('an account without a phone number cannot write its own profile', async () => {
    // The token has no phone number, so the write is denied by the rule; the payload still needs a defined
    // value (the SDK rejects `undefined` before the rules run).
    await assertFails(profileRef(users.emailOnly).set(validProfile(users.emailOnly, { phoneNumber: '+905551112233' })));
  });
});

describe('users/<uid>/profile — validation', () => {
  test('a missing required field is rejected', async () => {
    const fields = [
      'name', 'surname',
      'university', 'universityId', 'universityIsCustom',
      'faculty', 'facultyId', 'facultyIsCustom',
      'department', 'departmentId', 'departmentIsCustom',
      'gender', 'phoneNumber', 'updatedAt',
    ];
    for (const field of fields) {
      const profile = validProfile(users.alice);
      delete profile[field];
      await assertDenied(profileRef(users.alice).set(profile), `missing ${field}`);
    }
  });

  test('an unknown extra field is rejected', async () => {
    await assertFails(profileRef(users.alice).set(validProfile(users.alice, { nickname: 'ace' })));
  });

  test('an invalid gender value is rejected', async () => {
    for (const gender of ['other', 'Female', '', 'kadın']) {
      await assertDenied(profileRef(users.alice).set(validProfile(users.alice, { gender })), `gender=${gender}`);
    }
  });

  test('an over-long name or university is rejected', async () => {
    await assertDenied(profileRef(users.alice).set(validProfile(users.alice, { name: 'a'.repeat(61) })), 'name 61');
    await assertDenied(profileRef(users.alice).set(validProfile(users.alice, { university: 'u'.repeat(121) })), 'university 121');
  });

  test('an empty or whitespace-only field is rejected', async () => {
    await assertDenied(profileRef(users.alice).set(validProfile(users.alice, { name: '' })), 'empty name');
    await assertDenied(profileRef(users.alice).set(validProfile(users.alice, { surname: '   ' })), 'blank surname');
  });

  test('a field containing a database-illegal character is rejected', async () => {
    for (const bad of ['Ay/şe', 'A.B', 'x#y', '[z]', 'a$b']) {
      await assertDenied(profileRef(users.alice).set(validProfile(users.alice, { name: bad })), `name=${bad}`);
    }
  });

  test('a phone number that does not match the token is rejected', async () => {
    await assertFails(profileRef(users.alice).set(validProfile(users.alice, { phoneNumber: users.bob.token.phone_number })));
  });

  test('updatedAt must be the server timestamp', async () => {
    await assertFails(profileRef(users.alice).set(validProfile(users.alice, { updatedAt: 1_700_000_000_000 })));
  });

  test('a canonical id must be a lowercase slug', async () => {
    for (const bad of ['Bogazici', 'bogazici universitesi', 'bogazici_uni', 'boğaziçi', '']) {
      await assertDenied(profileRef(users.alice).set(validProfile(users.alice, { universityId: bad })), `universityId=${bad}`);
    }
  });

  test('a valid custom (free-typed) selection is accepted', async () => {
    await assertSucceeds(profileRef(users.alice).set(validProfile(users.alice, {
      university: 'Küçük Köy Üniversitesi',
      universityId: 'kucuk-koy-universitesi',
      universityIsCustom: true,
    })));
  });

  test('an isCustom flag must be a boolean', async () => {
    await assertFails(profileRef(users.alice).set(validProfile(users.alice, { universityIsCustom: 'true' })));
  });
});

describe('users/<uid>/profile — admin', () => {
  test('an admin can read any profile and list all users', async () => {
    await assertSucceeds(db(users.admin).ref('users/bob/profile').get());
    await assertSucceeds(db(users.admin).ref('users').get());
  });

  test('an admin cannot write a user profile', async () => {
    await assertFails(db(users.admin).ref('users/bob/profile').set(validProfile(users.bob)));
  });

  test('a forged string admin claim cannot read another user profile', async () => {
    await assertFails(db(users.fakeAdmin).ref('users/bob/profile').get());
  });
});

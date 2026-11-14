// Practice mode ("Sınava gir", 4.2.0): the `nextPracticeQuestions` callable (`functions/conversions/practice.js`)
// against the Firestore emulator — the free daily allowance (5 a day, Istanbul midnight, re-delivery not counted),
// Premium through a verified (fake) store proof and its `subscriptions/<uid>` cache, `exclude` and exhausted pools,
// the three scopes, multi-part pools, input validation and the enrichment (exam title, university name) — plus the
// pure helpers. The store verifier is a fake; nothing reaches Apple, Google or a real project.

import { test, before, after, beforeEach, describe, mock } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { assertLocalEmulators, PROJECT_ID } from './helpers.mjs';

const requireFromFunctions = createRequire(new URL('../functions/package.json', import.meta.url));
const { getFirestore, Timestamp } = requireFromFunctions('firebase-admin/firestore');
const { getApp, deleteApp } = requireFromFunctions('firebase-admin/app');

const NOON = new Date('2026-11-14T09:00:00Z'); // 12:00 in Türkiye
const MONTHLY = 'com.BuyukerYazilim.ViFi2.premium.monthly';
const SUBJECT = 'algoritmalar';
const EGE = 'ege-universitesi';
const COURSE = `${EGE}__muh__bil__algoritmalar`;
const USER = { uid: 'ayse', token: { phone_number: '+905551112233' } };

let db;
let fns;
let practice;
let schema;

before(async () => {
  assertLocalEmulators('FIRESTORE_EMULATOR_HOST');
  mock.method(console, 'warn', () => {});
  mock.method(console, 'error', () => {});
  fns = await import('../functions/index.js');
  practice = await import('../functions/conversions/practice.js');
  schema = await import('../functions/conversions/schema.js');
  db = getFirestore('vifi');
});

after(async () => {
  await deleteApp(getApp());
});

beforeEach(async () => {
  const host = process.env.FIRESTORE_EMULATOR_HOST;
  const response = await fetch(`http://${host}/emulator/v1/projects/${PROJECT_ID}/databases/vifi/documents`, { method: 'DELETE' });
  assert.ok(response.ok, `clearing the Firestore emulator failed: ${response.status}`);
});

// --- Fixtures -----------------------------------------------------------------------------------------------------

const poolRef = (scope, part = 1) => db.collection('questionPools').doc(schema.questionPoolId({
  subjectId: SUBJECT, examType: 'final', part, ...scope,
}));
const COURSE_SCOPE = { scope: 'course', courseId: COURSE };
const UNI_SCOPE = { scope: 'university', universityId: EGE };
const TR_SCOPE = { scope: 'tr' };
const dailyRef = (uid = USER.uid) => db.collection('users').doc(uid).collection('practice').doc('daily');

/** `n` published questions of exam `examId` and the given pool part holding their ids. */
async function seedQuestions(examId, n, { scope = COURSE_SCOPE, part = 1, examData = {}, universityId = EGE } = {}) {
  await db.collection('exams').doc(examId).set({
    title: '2019 FİNAL', universityId, universityName: 'Ege Üniversitesi', courseId: COURSE, status: 'published', ...examData,
  });
  const ids = [];
  for (let order = 1; order <= n; order += 1) {
    const id = `${examId}-${String(order).padStart(3, '0')}`;
    ids.push(id);
    await db.collection('questions').doc(id).set({
      schemaVersion: 1, examId, order, label: String(order), text: `Soru ${order}`, speech: `Soru ${order}`, choices: [],
      figures: [], answer: { text: 'Cevap' }, solution: [], topics: [], difficulty: 2, hasFigure: false,
      subjectId: SUBJECT, courseId: COURSE, universityId, examType: 'final', year: 2019,
      updatedAt: Timestamp.fromDate(NOON),
    });
  }
  await poolRef(scope, part).set({ subjectId: SUBJECT, examType: 'final', part, ids, count: ids.length });
  return ids;
}

/** The deps with a fixed clock, a seeded random and a fake store verifier. */
function deps({ now = NOON, verify = async () => null } = {}) {
  let seed = 7;
  const random = () => {
    seed = (seed * 16807) % 2147483647;
    return (seed - 1) / 2147483646;
  };
  const calls = [];
  return {
    calls,
    db,
    now: () => now,
    random,
    verifySubscriptionProof: async (proof) => {
      calls.push(proof);
      return verify(proof);
    },
  };
}

const call = (d, data, user = USER) => practice.nextPracticeQuestionsHandler(d, { auth: user, data });
const request = (overrides = {}) => ({ subjectId: SUBJECT, examType: 'final', ...COURSE_SCOPE, count: 1, ...overrides });
const ids = (result) => result.questions.map((question) => question.id);
const validPayload = (now = NOON, overrides = {}) => ({
  productId: MONTHLY, originalTransactionId: 'orig-1', transactionId: 't-1',
  expiresDate: now.getTime() + 30 * 24 * 60 * 60 * 1000, ...overrides,
});
const IOS_PROOF = { platform: 'ios', jws: 'header.payload.signature' };

// --- Free daily allowance ----------------------------------------------------------------------------------------

describe('free users: 5 questions a day', () => {
  test('counts delivered questions, stops at 5 and reports the limit', async () => {
    const all = await seedQuestions('E1', 8);
    const d = deps();
    const first = await call(d, request({ count: 3 }));
    assert.equal(first.questions.length, 3);
    assert.equal(first.poolSize, 8);
    assert.equal(first.remainingToday, 2);
    assert.equal(first.limitReached, false);
    assert.ok(ids(first).every((id) => all.includes(id)));

    const second = await call(d, request({ count: 10, exclude: ids(first) }));
    assert.equal(second.questions.length, 2);
    assert.equal(second.remainingToday, 0);
    assert.equal(second.limitReached, true);
    assert.equal(new Set([...ids(first), ...ids(second)]).size, 5);

    const third = await call(d, request({ count: 10, exclude: [...ids(first), ...ids(second)] }));
    assert.deepEqual(third.questions, []);
    assert.equal(third.remainingToday, 0);
    assert.equal(third.limitReached, true);

    const daily = (await dailyRef().get()).data();
    assert.equal(daily.day, '2026-11-14');
    assert.equal(daily.count, 5);
    assert.deepEqual([...daily.seenToday].sort(), [...ids(first), ...ids(second)].sort());
    assert.equal(d.calls.length, 0);
  });

  test('a question re-delivered the same day is not counted twice, even after the limit', async () => {
    const all = await seedQuestions('E2', 2);
    const d = deps();
    const first = await call(d, request({ count: 2 }));
    assert.equal(first.remainingToday, 3);
    // A new session (no `exclude`) gets the same two questions back: still 3 left.
    const again = await call(d, request({ count: 2 }));
    assert.deepEqual([...ids(again)].sort(), all);
    assert.equal(again.remainingToday, 3);
    assert.equal((await dailyRef().get()).get('count'), 2);

    // With the allowance used up, today's questions can still be seen again; new ones cannot.
    await dailyRef().update({ count: 5 });
    const extra = await seedQuestions('E3', 3, { scope: UNI_SCOPE });
    await poolRef(COURSE_SCOPE).update({ ids: [...all, ...extra] });
    const more = await call(d, request({ count: 5 }));
    assert.deepEqual([...ids(more)].sort(), all);
    assert.equal(more.remainingToday, 0);
    assert.equal(more.limitReached, true);
  });

  test('the day rolls over at midnight in Istanbul (21:00 UTC)', async () => {
    await seedQuestions('E4', 10);
    const before = new Date('2026-11-14T20:59:59Z'); // 23:59:59 in Türkiye
    const used = await call(deps({ now: before }), request({ count: 5 }));
    assert.equal(used.remainingToday, 0);
    assert.equal((await dailyRef().get()).get('day'), '2026-11-14');
    const blocked = await call(deps({ now: before }), request({ count: 1, exclude: ids(used) }));
    assert.deepEqual(blocked.questions, []);

    const after = new Date('2026-11-14T21:00:00Z'); // 00:00 on the 15th in Türkiye
    const next = await call(deps({ now: after }), request({ count: 2, exclude: ids(used) }));
    assert.equal(next.questions.length, 2);
    assert.equal(next.remainingToday, 3);
    const daily = (await dailyRef().get()).data();
    assert.equal(daily.day, '2026-11-15');
    assert.equal(daily.count, 2);
    assert.deepEqual([...daily.seenToday].sort(), [...ids(next)].sort());
  });

  test('accounts are counted separately', async () => {
    await seedQuestions('E5', 6);
    const d = deps();
    await call(d, request({ count: 5 }));
    const other = await call(d, request({ count: 5 }), { uid: 'can', token: { phone_number: '+905559998877' } });
    assert.equal(other.questions.length, 5);
    assert.equal(other.remainingToday, 0);
    assert.equal((await dailyRef('can').get()).get('count'), 5);
  });
});

// --- Premium ------------------------------------------------------------------------------------------------------

describe('Premium: a verified subscription proof', () => {
  test('a valid proof is unlimited, writes no counter and caches the subscription', async () => {
    await seedQuestions('P1', 12);
    const d = deps({ verify: async () => validPayload() });
    const result = await call(d, request({ count: 10, subscriptionProof: IOS_PROOF }));
    assert.equal(result.questions.length, 10);
    assert.equal(result.remainingToday, null);
    assert.equal(result.limitReached, false);
    assert.deepEqual(d.calls, [IOS_PROOF]);
    assert.equal((await dailyRef().get()).exists, false);

    const cached = (await db.collection('subscriptions').doc(USER.uid).get()).data();
    assert.equal(cached.platform, 'ios');
    assert.equal(cached.productId, MONTHLY);
    assert.equal(cached.originalTransactionId, 'orig-1');
    assert.equal(cached.expiresAt.toMillis(), validPayload().expiresDate);
    assert.equal(cached.verifiedAt.toMillis(), NOON.getTime());
  });

  test('a cached subscription is reused without verifying again until it expires', async () => {
    await seedQuestions('P2', 12);
    await db.collection('subscriptions').doc(USER.uid).set({
      platform: 'ios', productId: MONTHLY, originalTransactionId: 'orig-1',
      expiresAt: Timestamp.fromMillis(NOON.getTime() + 60_000), verifiedAt: Timestamp.fromDate(NOON),
    });
    const d = deps({ verify: async () => { throw new Error('must not be called'); } });
    const result = await call(d, request({ count: 8 }));
    assert.equal(result.questions.length, 8);
    assert.equal(result.remainingToday, null);
    assert.equal(d.calls.length, 0);

    // After `expiresAt` the cache no longer counts: without a proof the free rules apply.
    const later = new Date(NOON.getTime() + 120_000);
    const expired = await call(deps({ now: later }), request({ count: 8 }));
    assert.equal(expired.questions.length, 5);
    assert.equal(expired.remainingToday, 0);
  });

  test('a cached subscription older than 24 hours needs a fresh proof', async () => {
    await seedQuestions('P4', 12);
    await db.collection('subscriptions').doc(USER.uid).set({
      platform: 'ios', productId: MONTHLY, originalTransactionId: 'orig-1',
      expiresAt: Timestamp.fromMillis(NOON.getTime() + 10 * 24 * 60 * 60 * 1000), verifiedAt: Timestamp.fromDate(NOON),
    });
    const dayLater = new Date(NOON.getTime() + practice.SUBSCRIPTION_REVERIFY_MS);
    // Not expired, but verified a day ago: without a proof the free rules apply (a refunded entitlement is no longer sent).
    const stale = await call(deps({ now: dayLater }), request({ count: 8 }));
    assert.equal(stale.remainingToday, 0);
    assert.equal(stale.questions.length, 5);

    // With a fresh proof it is Premium again and the cache is renewed.
    await dailyRef().delete();
    const d = deps({ now: dayLater, verify: async () => validPayload(dayLater) });
    const fresh = await call(d, request({ count: 8, subscriptionProof: IOS_PROOF }));
    assert.equal(fresh.remainingToday, null);
    assert.equal(d.calls.length, 1);
    const cached = (await db.collection('subscriptions').doc(USER.uid).get()).data();
    assert.equal(cached.verifiedAt.toMillis(), dayLater.getTime());
  });

  test('one subscription serves one account: another account proving it gets the free rules', async () => {
    await seedQuestions('P5', 12);
    const ownerRef = db.collection('subscriptionOwners').doc(practice.subscriptionOwnerId('ios', 'orig-1'));
    const first = deps({ verify: async () => validPayload() });
    assert.equal((await call(first, request({ count: 3, subscriptionProof: IOS_PROOF }))).remainingToday, null);
    assert.equal((await ownerRef.get()).get('uid'), USER.uid);

    const other = { uid: 'mehmet', token: { phone_number: '+905554443322' } };
    const second = deps({ verify: async () => validPayload() });
    const result = await call(second, request({ count: 10, subscriptionProof: IOS_PROOF }), other);
    assert.equal(result.remainingToday, 0);
    assert.equal(result.questions.length, 5);
    assert.equal((await db.collection('subscriptions').doc('mehmet').get()).exists, false);
    assert.equal((await ownerRef.get()).get('uid'), USER.uid, 'the binding does not move');

    // The owner keeps it, also after re-verification.
    const again = deps({ now: new Date(NOON.getTime() + practice.SUBSCRIPTION_REVERIFY_MS + 1), verify: async () => validPayload() });
    assert.equal((await call(again, request({ count: 1, subscriptionProof: IOS_PROOF }))).remainingToday, null);
  });

  test('subscriptionOwnerId keeps the id a single document segment', () => {
    assert.equal(practice.subscriptionOwnerId('ios', '2000001234'), 'ios-2000001234');
    assert.equal(practice.subscriptionOwnerId('android', 'GPA.1/2'), 'android-GPA.1_2');
  });

  test('an expired, revoked, non-subscription, rejected or Android proof falls back to the free rules', async () => {
    await seedQuestions('P3', 12);
    const cases = [
      ['expired', async () => validPayload(NOON, { expiresDate: NOON.getTime() - 1 })],
      ['revoked', async () => validPayload(NOON, { revocationDate: NOON.getTime() - 1000 })],
      ['exam unlock product', async () => validPayload(NOON, { productId: 'com.BuyukerYazilim.ViFi2.exam.unlock' })],
      ['bad signature', async () => { throw new Error('signature'); }],
      ['android (not verified yet)', async () => null],
    ];
    for (const [label, verify] of cases) {
      await dailyRef().delete();
      const d = deps({ verify });
      const proof = label.startsWith('android') ? { platform: 'android', purchaseToken: 'tok', productId: 'premium' } : IOS_PROOF;
      const result = await call(d, request({ count: 10, subscriptionProof: proof }));
      assert.equal(result.questions.length, 5, label);
      assert.equal(result.remainingToday, 0, label);
      assert.equal(d.calls.length, 1, label);
      assert.equal((await db.collection('subscriptions').doc(USER.uid).get()).exists, false, label);
    }
    // A malformed proof is not even sent to the verifier.
    await dailyRef().delete();
    const d = deps({ verify: async () => validPayload() });
    for (const proof of ['jws', { platform: 'ios' }, { platform: 'web', jws: 'x' }, { platform: 'ios', jws: 'x'.repeat(60_000) }]) {
      const result = await call(d, request({ count: 1, subscriptionProof: proof }));
      assert.notEqual(result.remainingToday, null);
    }
    assert.equal(d.calls.length, 0);
  });
});

// --- Pools, scopes and the returned questions ---------------------------------------------------------------------

describe('pools and scopes', () => {
  test('exclude leaves seen questions out; an exhausted pool returns [] and counts nothing', async () => {
    const all = await seedQuestions('X1', 3);
    const d = deps();
    const one = await call(d, request({ count: 3, exclude: all.slice(0, 2) }));
    assert.deepEqual(ids(one), [all[2]]);
    const none = await call(d, request({ count: 3, exclude: all }));
    assert.deepEqual(none, { questions: [], poolSize: 3, remainingToday: 4, limitReached: false });
    // A pool that does not exist is simply empty.
    const missing = await call(d, request({ subjectId: 'yok' }));
    assert.deepEqual(missing, { questions: [], poolSize: 0, remainingToday: 4, limitReached: false });
  });

  test('course, university and tr scopes read their own pools', async () => {
    const course = await seedQuestions('S1', 2, { scope: COURSE_SCOPE });
    const uni = await seedQuestions('S2', 2, { scope: UNI_SCOPE });
    const tr = await seedQuestions('S3', 2, { scope: TR_SCOPE });
    const d = deps({ verify: async () => validPayload() });
    const premium = { count: 10, subscriptionProof: IOS_PROOF };
    assert.deepEqual([...ids(await call(d, request({ ...premium, ...COURSE_SCOPE })))].sort(), course);
    assert.deepEqual([...ids(await call(d, request({ ...premium, scope: 'university', universityId: EGE })))].sort(), uni);
    assert.deepEqual([...ids(await call(d, { subjectId: SUBJECT, examType: 'final', scope: 'tr', ...premium }))].sort(), tr);
  });

  test('a pool split into __pN parts is read whole', async () => {
    const part1 = await seedQuestions('M1', 3, { part: 1 });
    const part2 = await seedQuestions('M2', 2, { part: 2 });
    const d = deps({ verify: async () => validPayload() });
    const result = await call(d, request({ count: 10, subscriptionProof: IOS_PROOF }));
    assert.equal(result.poolSize, 5);
    assert.deepEqual([...ids(result)].sort(), [...part1, ...part2].sort());
    // Excluding part 1 leaves only part 2.
    const rest = await call(d, request({ count: 10, exclude: part1 }));
    assert.deepEqual([...ids(rest)].sort(), part2);
  });

  test('questions come in the published shape with exam title and university name', async () => {
    await seedQuestions('Q1', 1);
    await db.collection('catalogNodes').doc('bozok').set({ level: 'university', name: 'Bozok Üniversitesi', parentId: '' });
    await seedQuestions('Q2', 1, { scope: UNI_SCOPE, universityId: 'bozok', examData: { universityName: '', title: '2020 VİZE' } });
    const d = deps({ verify: async () => validPayload() });
    const [question] = (await call(d, request({ count: 1, subscriptionProof: IOS_PROOF }))).questions;
    assert.equal(question.id, 'Q1-001');
    assert.equal(question.examId, 'Q1');
    assert.equal(question.text, 'Soru 1');
    assert.deepEqual(question.answer, { text: 'Cevap' });
    assert.equal(question.examTitle, '2019 FİNAL');
    assert.equal(question.universityName, 'Ege Üniversitesi');
    assert.equal(question.updatedAt, NOON.getTime());

    const [fallback] = (await call(d, request({ count: 1, scope: 'university', universityId: EGE }))).questions;
    assert.equal(fallback.examTitle, '2020 VİZE');
    assert.equal(fallback.universityName, 'Bozok Üniversitesi');
  });
});

// --- Validation and auth ------------------------------------------------------------------------------------------

describe('validation', () => {
  test('a caller without a +90 number is refused', async () => {
    for (const auth of [null, { uid: 'x', token: { phone_number: '+15551234567' } }, { uid: 'admin', token: { admin: true } }]) {
      await assert.rejects(practice.nextPracticeQuestionsHandler(deps(), { auth, data: request() }), { code: 'permission-denied' });
    }
  });

  test('study materials, unknown types, bad scopes, counts and exclude lists are refused', async () => {
    const d = deps();
    for (const data of [
      request({ examType: 'odev' }),
      request({ examType: 'cozumlu-sorular' }),
      request({ examType: 'sinav' }),
      request({ subjectId: 'a/b' }),
      request({ scope: 'department' }),
      { subjectId: SUBJECT, examType: 'final', scope: 'course' },
      { subjectId: SUBJECT, examType: 'final', scope: 'university', courseId: COURSE },
      request({ count: 0 }),
      request({ count: 11 }),
      request({ count: 1.5 }),
      request({ exclude: 'E1-001' }),
      request({ exclude: [1] }),
      request({ exclude: Array.from({ length: 301 }, (_, k) => `x-${k}`) }),
    ]) {
      await assert.rejects(call(d, data), { code: 'invalid-argument' }, JSON.stringify(data).slice(0, 80));
    }
    // Every practice type is accepted (and the default count is 1).
    for (const examType of schema.PRACTICE_EXAM_TYPES) {
      const result = await call(d, { subjectId: SUBJECT, examType, scope: 'tr' });
      assert.equal(result.poolSize, 0);
    }
    assert.equal(typeof fns.nextPracticeQuestions, 'function');
  });
});

// --- Pure helpers -------------------------------------------------------------------------------------------------

describe('pure helpers', () => {
  test('istanbulDay', () => {
    assert.equal(practice.istanbulDay(new Date('2026-11-14T20:59:59Z')), '2026-11-14');
    assert.equal(practice.istanbulDay(new Date('2026-11-14T21:00:00Z')), '2026-11-15');
    assert.equal(practice.istanbulDay(new Date('2026-12-31T21:30:00Z')), '2027-01-01');
  });

  test('dailyState resets on a new day', () => {
    assert.deepEqual(practice.dailyState(null, '2026-11-14'), { count: 0, seenToday: [] });
    assert.deepEqual(practice.dailyState({ day: '2026-11-13', count: 5, seenToday: ['a'] }, '2026-11-14'), { count: 0, seenToday: [] });
    assert.deepEqual(practice.dailyState({ day: '2026-11-14', count: 3, seenToday: ['a', 1] }, '2026-11-14'), { count: 3, seenToday: ['a'] });
  });

  test('pickQuestions: random, unique, capped for new ids only', () => {
    const candidates = Array.from({ length: 20 }, (_, k) => `q${k}`);
    const all = practice.pickQuestions({ candidates, count: 10 });
    assert.equal(new Set(all).size, 10);
    assert.ok(all.every((id) => candidates.includes(id)));
    assert.equal(practice.pickQuestions({ candidates: ['a', 'b'], count: 10 }).length, 2);
    const capped = practice.pickQuestions({ candidates, count: 10, remaining: 2, seenToday: new Set(['q1', 'q2', 'q3']) });
    assert.equal(capped.filter((id) => !['q1', 'q2', 'q3'].includes(id)).length, 2);
    assert.equal(capped.length, 5);
    assert.deepEqual(practice.pickQuestions({ candidates, count: 3, remaining: 0 }), []);
  });

  test('subscriptionFromTransaction', () => {
    assert.deepEqual(practice.subscriptionFromTransaction(validPayload(), NOON), {
      platform: 'ios', productId: MONTHLY, originalTransactionId: 'orig-1', expiresAt: new Date(validPayload().expiresDate),
    });
    assert.equal(practice.subscriptionFromTransaction(validPayload(NOON, { productId: 'x' }), NOON), null);
    assert.equal(practice.subscriptionFromTransaction(validPayload(NOON, { expiresDate: NOON.getTime() }), NOON), null);
    assert.equal(practice.subscriptionFromTransaction(validPayload(NOON, { expiresDate: undefined }), NOON), null);
    assert.equal(practice.subscriptionFromTransaction(validPayload(NOON, { revocationDate: 1 }), NOON), null);
    assert.equal(practice.subscriptionFromTransaction(null, NOON), null);
  });
});

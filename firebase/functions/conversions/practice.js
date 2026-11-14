// Practice mode ("Sınava gir", 4.2.0; contract: schema.js PRACTICE MODE; owner decisions P1–P5, 14 Nov 2026): the
// `nextPracticeQuestions` callable. Questions are handed out here, not read by the app from `questions`, so the free
// daily allowance cannot be bypassed in the app.
//
// One call: validate → Premium? (`subscriptions/<uid>` cache, else the client's `subscriptionProof` verified and
// cached) → read the pool (every `__pN` part) → a transaction on `users/<uid>/practice/daily` that picks random ids
// not in `exclude`, reads those questions (≤ 10) and, for a free user, counts the new ones against the day's
// allowance → the exams' titles and university names are added → the questions go back with the pool size and what is
// left today.
//
// Handlers take their dependencies (`db`, `now`, `random`, `verifySubscriptionProof`) as the first argument, like the
// notification handlers, so the tests run them against the Firestore emulator with a fake store verifier.

import { Timestamp } from 'firebase-admin/firestore';
import { HttpsError } from 'firebase-functions/v2/https';
import * as logger from 'firebase-functions/logger';
import {
  ID_SEGMENT_PATTERN,
  PRACTICE_EXAM_TYPES,
  PRACTICE_FREE_DAILY_LIMIT,
  PRACTICE_MAX_BATCH,
  PRACTICE_MAX_EXCLUDE,
  questionPoolId,
} from './schema.js';
import { SUBSCRIPTION_PRODUCT_IDS } from '../appStore.js';
import { requirePhoneUser } from '../notifications/stats.js';

/** Ids remembered per day so a re-delivered question is not counted twice (contract: ≤ 50). */
export const PRACTICE_SEEN_TODAY_LIMIT = 50;
/** Safety stop when walking a pool's `__pN` parts (as publish.js). */
const MAX_POOL_PARTS = 50;
/** A question id is `<examId>-<nnn>`; anything longer than this cannot be one. */
const MAX_QUESTION_ID_LENGTH = 720;
/** A StoreKit JWS is a few KB; anything far larger is not one. */
const MAX_JWS_LENGTH = 50_000;
const SCOPES = Object.freeze(['course', 'university', 'tr']);

// MARK: - Pure helpers

/** The practice day `YYYY-MM-DD` in Europe/Istanbul (UTC+3 all year, like `usageMonthKey`). */
export function istanbulDay(date) {
  return new Date(date.getTime() + 3 * 60 * 60 * 1000).toISOString().slice(0, 10);
}

/**
 * The validated request: the pool spec, `exclude` as a Set and `count`. `invalid-argument` (Turkish message) for
 * anything else; a study-material type (not in `PRACTICE_EXAM_TYPES`) is refused.
 */
export function practiceRequest(data) {
  const { subjectId, examType, scope, courseId, universityId } = data ?? {};
  if (typeof subjectId !== 'string' || !ID_SEGMENT_PATTERN.test(subjectId)) throw invalid('Ders kimliği geçersiz.');
  if (!PRACTICE_EXAM_TYPES.includes(examType)) throw invalid('Bu sınav türüyle pratik yapılamaz.');
  if (!SCOPES.includes(scope)) throw invalid('Kapsam geçersiz.');
  const spec = { subjectId, examType, scope };
  if (scope === 'course') {
    if (typeof courseId !== 'string' || !ID_SEGMENT_PATTERN.test(courseId)) throw invalid('Ders kimliği eksik.');
    spec.courseId = courseId;
  } else if (scope === 'university') {
    if (typeof universityId !== 'string' || !ID_SEGMENT_PATTERN.test(universityId)) throw invalid('Üniversite kimliği eksik.');
    spec.universityId = universityId;
  }

  const rawExclude = data?.exclude ?? [];
  if (!Array.isArray(rawExclude) || rawExclude.length > PRACTICE_MAX_EXCLUDE
    || !rawExclude.every((id) => typeof id === 'string' && id.length > 0 && id.length <= MAX_QUESTION_ID_LENGTH)) {
    throw invalid('Görülen soru listesi geçersiz.');
  }
  const count = data?.count ?? 1;
  if (!Number.isInteger(count) || count < 1 || count > PRACTICE_MAX_BATCH) throw invalid('Soru sayısı geçersiz.');
  return { spec, exclude: new Set(rawExclude), count };
}

/** The daily counter for `day`: the stored one, or a fresh `{ count: 0, seenToday: [] }` on a new day. */
export function dailyState(stored, day) {
  if (!stored || stored.day !== day) return { count: 0, seenToday: [] };
  return {
    count: Number.isInteger(stored.count) && stored.count > 0 ? stored.count : 0,
    seenToday: Array.isArray(stored.seenToday) ? stored.seenToday.filter((id) => typeof id === 'string') : [],
  };
}

/**
 * Up to `count` random ids of `candidates`. `remaining` (`null` = Premium, unlimited) caps the NEW ids for a free user;
 * ids in `seenToday` (already counted today) are always allowed. `random()` returns [0, 1).
 */
export function pickQuestions({ candidates, count, remaining = null, seenToday = new Set(), random = Math.random }) {
  const pool = [...candidates];
  const picked = [];
  let fresh = 0;
  for (let end = pool.length; end > 0 && picked.length < count; end -= 1) {
    // Partial Fisher–Yates: move a random remaining id to the end of the unvisited range.
    const index = Math.min(end - 1, Math.floor(random() * end));
    [pool[index], pool[end - 1]] = [pool[end - 1], pool[index]];
    const id = pool[end - 1];
    if (seenToday.has(id)) {
      picked.push(id);
    } else if (remaining === null || fresh < remaining) {
      picked.push(id);
      fresh += 1;
    }
  }
  return picked;
}

/**
 * The cached-subscription record of a verified store transaction, or `null` when it does not grant Premium now: not a
 * subscription product, revoked, no original transaction id or `expiresDate` not after `now`.
 */
export function subscriptionFromTransaction(payload, now, platform = 'ios') {
  if (!payload || !SUBSCRIPTION_PRODUCT_IDS.includes(payload.productId)) return null;
  if (payload.revocationDate !== undefined && payload.revocationDate !== null) return null;
  const expiresMs = Number(payload.expiresDate);
  if (!Number.isFinite(expiresMs) || expiresMs <= now.getTime()) return null;
  const originalTransactionId = payload.originalTransactionId ?? payload.transactionId;
  if (typeof originalTransactionId !== 'string' || originalTransactionId === '') return null;
  return { platform, productId: payload.productId, originalTransactionId, expiresAt: new Date(expiresMs) };
}

/** A usable `subscriptionProof` (`{ platform: 'ios', jws }` or `{ platform: 'android', purchaseToken, productId }`). */
export function validProof(proof) {
  if (proof === null || typeof proof !== 'object' || Array.isArray(proof)) return null;
  if (proof.platform === 'ios' && typeof proof.jws === 'string' && proof.jws.length > 0 && proof.jws.length <= MAX_JWS_LENGTH) {
    return { platform: 'ios', jws: proof.jws };
  }
  if (proof.platform === 'android' && typeof proof.purchaseToken === 'string' && proof.purchaseToken.length > 0
    && proof.purchaseToken.length <= 4096 && typeof proof.productId === 'string') {
    return { platform: 'android', purchaseToken: proof.purchaseToken, productId: proof.productId };
  }
  return null;
}

// MARK: - nextPracticeQuestions

/**
 * `nextPracticeQuestions` `{ subjectId, examType, scope, courseId?, universityId?, exclude?, count?, subscriptionProof? }`
 * → `{ questions, poolSize, remainingToday, limitReached }` (contract: schema.js PRACTICE MODE).
 *
 * @param {{ db: import('firebase-admin/firestore').Firestore, now?: () => Date, random?: () => number,
 *   verifySubscriptionProof: (proof: object) => Promise<object|null> }} deps
 */
export async function nextPracticeQuestionsHandler(deps, request) {
  const uid = requirePhoneUser(request);
  const { spec, exclude, count } = practiceRequest(request.data);
  const { db } = deps;
  const now = deps.now?.() ?? new Date();
  const random = deps.random ?? Math.random;

  const premium = await isPremium(deps, uid, request.data?.subscriptionProof, now);
  const poolIds = await readPoolIds(db, spec);
  const candidates = poolIds.filter((id) => !exclude.has(id));
  const questionRef = (id) => db.collection('questions').doc(id);

  let documents;
  let remainingToday = null;
  if (premium) {
    const picked = pickQuestions({ candidates, count, random });
    documents = picked.length > 0 ? (await db.getAll(...picked.map(questionRef))).filter((doc) => doc.exists) : [];
  } else {
    const day = istanbulDay(now);
    const dailyRef = db.collection('users').doc(uid).collection('practice').doc('daily');
    ({ documents, remainingToday } = await db.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(dailyRef);
      const state = dailyState(snapshot.exists ? snapshot.data() : null, day);
      const seenToday = new Set(state.seenToday);
      const remaining = Math.max(0, PRACTICE_FREE_DAILY_LIMIT - state.count);
      const picked = pickQuestions({ candidates, count, remaining, seenToday, random });
      const found = picked.length > 0
        ? (await transaction.getAll(...picked.map(questionRef))).filter((doc) => doc.exists)
        : [];
      const fresh = found.map((doc) => doc.id).filter((id) => !seenToday.has(id));
      if (fresh.length > 0) {
        transaction.set(dailyRef, {
          day,
          count: state.count + fresh.length,
          seenToday: [...state.seenToday, ...fresh].slice(-PRACTICE_SEEN_TODAY_LIMIT),
          updatedAt: Timestamp.fromDate(now),
        });
      }
      return { documents: found, remainingToday: remaining - fresh.length };
    }));
  }

  return {
    questions: await enrichedQuestions(db, documents),
    poolSize: poolIds.length,
    remainingToday,
    limitReached: remainingToday === 0,
  };
}

/**
 * Premium = a cached subscription (`subscriptions/<uid>.expiresAt` after now) or a `subscriptionProof` that verifies
 * now (then cached). Anything else — no proof, a malformed or rejected one, a store error — is the free rules.
 */
async function isPremium(deps, uid, rawProof, now) {
  const ref = deps.db.collection('subscriptions').doc(uid);
  const cached = await ref.get();
  const cachedExpiry = cached.exists ? cached.get('expiresAt') : null;
  if (typeof cachedExpiry?.toMillis === 'function' && cachedExpiry.toMillis() > now.getTime()) return true;

  const proof = validProof(rawProof);
  if (!proof || typeof deps.verifySubscriptionProof !== 'function') return false;
  let payload;
  try {
    payload = await deps.verifySubscriptionProof(proof);
  } catch (error) {
    logger.warn('Practice: subscription proof rejected', { uid, platform: proof.platform, error: error?.message ?? String(error) });
    return false;
  }
  const subscription = subscriptionFromTransaction(payload, now, proof.platform);
  if (!subscription) return false;
  await ref.set({
    platform: subscription.platform,
    productId: subscription.productId,
    originalTransactionId: subscription.originalTransactionId,
    expiresAt: Timestamp.fromDate(subscription.expiresAt),
    verifiedAt: Timestamp.fromDate(now),
  });
  return true;
}

/** Every id of the pool (all `__pN` parts, in order); `[]` when the pool does not exist. */
export async function readPoolIds(db, spec) {
  const ids = [];
  for (let part = 1; part <= MAX_POOL_PARTS; part += 1) {
    const snapshot = await db.collection('questionPools').doc(questionPoolId({ ...spec, part })).get();
    if (!snapshot.exists) break;
    const partIds = snapshot.get('ids');
    if (Array.isArray(partIds)) ids.push(...partIds.filter((id) => typeof id === 'string'));
  }
  return [...new Set(ids)];
}

/**
 * The published questions as the app reads them (Ek A shape, `id` added, `updatedAt` as epoch ms) with `examTitle`
 * and `universityName` from their exams (the university node when the exam has no name). ≤ 10 exams + their
 * universities: two `getAll` reads at most.
 */
async function enrichedQuestions(db, documents) {
  if (documents.length === 0) return [];
  const examIds = [...new Set(documents.map((doc) => doc.get('examId')).filter((id) => ID_SEGMENT_PATTERN.test(id ?? '')))];
  const exams = new Map();
  if (examIds.length > 0) {
    for (const snapshot of await db.getAll(...examIds.map((id) => db.collection('exams').doc(id)))) {
      if (snapshot.exists) exams.set(snapshot.id, snapshot.data());
    }
  }
  const universityIdOf = (doc) => exams.get(doc.get('examId'))?.universityId ?? doc.get('universityId');
  const missingNames = [...new Set(documents
    .filter((doc) => !text(exams.get(doc.get('examId'))?.universityName))
    .map(universityIdOf)
    .filter((id) => ID_SEGMENT_PATTERN.test(id ?? '')))];
  const universityNames = new Map();
  if (missingNames.length > 0) {
    for (const snapshot of await db.getAll(...missingNames.map((id) => db.collection('catalogNodes').doc(id)))) {
      if (snapshot.exists) universityNames.set(snapshot.id, text(snapshot.get('name')));
    }
  }
  return documents.map((doc) => {
    const exam = exams.get(doc.get('examId'));
    const question = Object.fromEntries(Object.entries(doc.data())
      .map(([key, value]) => [key, typeof value?.toMillis === 'function' ? value.toMillis() : value]));
    return {
      ...question,
      id: doc.id,
      examTitle: text(exam?.title) || null,
      universityName: text(exam?.universityName) || universityNames.get(universityIdOf(doc)) || null,
    };
  });
}

function invalid(message) {
  return new HttpsError('invalid-argument', message);
}

function text(value) {
  return typeof value === 'string' ? value.trim() : '';
}

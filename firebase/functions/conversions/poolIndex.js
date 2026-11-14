// The practice-mode pool index (`questionPoolIndex/<subjectId>`, contract: schema.js PRACTICE MODE): one document per
// subject with the question count of every practice pool, so the app shows the "Sınava gir" button and the per-type /
// per-scope counts with a single read.
//
// Shape: `{ subjectId, name, types: { <practice examType>: { tr: n, "u-<universityId>": n, "c-<courseId>": n } },
// updatedAt }`. Only pools with at least one question are listed; a type without any is left out, and a subject without
// any pool has no index document (it is deleted).
//
// The index is written in the SAME transaction that changes the pools (publish.js: publish, K21 subject move, exam
// deletion cleanup): `readPoolIndexes` (reads, before any write) + `writePoolIndexes` (with the totals `writePools`
// returns). `scripts/rebuild-pool-index.mjs` builds it once for pools written before the index existed.
//
// No Firebase imports: the maintenance script and the unit tests use it as is.

import { ID_SEGMENT_PATTERN, PRACTICE_EXAM_TYPES } from './schema.js';

export const POOL_INDEX_COLLECTION = 'questionPoolIndex';

/** The index key of a pool scope: `tr`, `u-<universityId>` or `c-<courseId>` (the pool id's last segment). */
export function poolScopeKey(spec) {
  if (spec?.scope === 'tr') return 'tr';
  if (spec?.scope === 'university' && ID_SEGMENT_PATTERN.test(spec.universityId ?? '')) return `u-${spec.universityId}`;
  if (spec?.scope === 'course' && ID_SEGMENT_PATTERN.test(spec.courseId ?? '')) return `c-${spec.courseId}`;
  return null;
}

/**
 * `types` with the given pool totals applied (`[{ examType, scopeKey, count }]`): a positive count is set, zero removes
 * the scope, a type left without scopes is removed. Non-practice types and malformed entries already in `types` are
 * dropped. Pure; returns a new object.
 */
export function applyPoolCounts(types, counts) {
  const next = {};
  for (const [examType, scopes] of Object.entries(isPlainObject(types) ? types : {})) {
    if (!PRACTICE_EXAM_TYPES.includes(examType) || !isPlainObject(scopes)) continue;
    const kept = Object.fromEntries(Object.entries(scopes).filter(([, count]) => Number.isInteger(count) && count > 0));
    if (Object.keys(kept).length > 0) next[examType] = kept;
  }
  for (const { examType, scopeKey, count } of counts) {
    if (!PRACTICE_EXAM_TYPES.includes(examType) || !scopeKey) continue;
    if (Number.isInteger(count) && count > 0) {
      next[examType] = { ...(next[examType] ?? {}), [scopeKey]: count };
    } else if (next[examType]) {
      const { [scopeKey]: _removed, ...rest } = next[examType];
      if (Object.keys(rest).length > 0) next[examType] = rest;
      else delete next[examType];
    }
  }
  return next;
}

/** True when the index lists at least one question (the app's "Sınava gir" button condition). */
export function hasPracticeQuestions(types) {
  return Object.values(isPlainObject(types) ? types : {})
    .some((scopes) => Object.values(scopes ?? {}).some((count) => Number.isInteger(count) && count > 0));
}

/**
 * Reads the index documents (and, when an index has no name yet, the subject documents) of every subject `pools`
 * touches — `pools` as `readPools` returns it. Reads only, so the caller writes afterwards in the same transaction.
 * `names` (`{ subjectId: name }`) gives names known to the caller (a subject created in this very transaction).
 *
 * @returns {Promise<Map<string, { ref: object, exists: boolean, types: object, name: string }>>}
 */
export async function readPoolIndexes(transaction, db, pools, names = {}) {
  const subjectIds = [...new Set([...pools.values()].map((pool) => pool.spec.subjectId))]
    .filter((subjectId) => ID_SEGMENT_PATTERN.test(subjectId ?? ''));
  const indexes = new Map();
  if (subjectIds.length === 0) return indexes;
  const refs = subjectIds.map((subjectId) => db.collection(POOL_INDEX_COLLECTION).doc(subjectId));
  const snapshots = await transaction.getAll(...refs);
  const unnamed = [];
  snapshots.forEach((snapshot, position) => {
    const subjectId = subjectIds[position];
    const storedName = snapshot.exists ? text(snapshot.get('name')) : '';
    const name = text(names[subjectId]) || storedName;
    indexes.set(subjectId, {
      ref: refs[position],
      exists: snapshot.exists,
      types: snapshot.exists ? snapshot.get('types') ?? {} : {},
      name,
    });
    if (!name) unnamed.push(subjectId);
  });
  if (unnamed.length > 0) {
    const subjects = await transaction.getAll(...unnamed.map((subjectId) => db.collection('subjects').doc(subjectId)));
    subjects.forEach((snapshot, position) => {
      const index = indexes.get(unnamed[position]);
      index.name = (snapshot.exists ? text(snapshot.get('name')) : '') || unnamed[position];
    });
  }
  return indexes;
}

/**
 * Writes the index documents read by `readPoolIndexes` with `totals` (`Map<poolBase, { spec, count }>`, from
 * `writePools`). A document whose types end up empty is deleted (or not created). Unchanged documents are not written.
 */
export function writePoolIndexes(transaction, indexes, totals, now) {
  const countsBySubject = new Map();
  for (const { spec, count } of totals.values()) {
    if (!countsBySubject.has(spec.subjectId)) countsBySubject.set(spec.subjectId, []);
    countsBySubject.get(spec.subjectId).push({ examType: spec.examType, scopeKey: poolScopeKey(spec), count });
  }
  for (const [subjectId, counts] of countsBySubject) {
    const index = indexes.get(subjectId);
    if (!index) continue;
    const types = applyPoolCounts(index.types, counts);
    if (!hasPracticeQuestions(types)) {
      if (index.exists) transaction.delete(index.ref);
      continue;
    }
    if (index.exists && sameTypes(types, index.types)) continue;
    transaction.set(index.ref, poolIndexDocument({ subjectId, name: index.name, types, updatedAt: now }));
  }
}

/** The full index document. */
export function poolIndexDocument({ subjectId, name, types, updatedAt }) {
  return { subjectId, name: text(name) || subjectId, types, updatedAt };
}

function sameTypes(a, b) {
  const normalise = (types) => JSON.stringify(Object.keys(types ?? {}).sort().map((type) => [
    type, Object.entries(types[type] ?? {}).sort(([x], [y]) => (x < y ? -1 : x > y ? 1 : 0)),
  ]));
  return normalise(a) === normalise(b);
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function text(value) {
  return typeof value === 'string' ? value.trim() : '';
}

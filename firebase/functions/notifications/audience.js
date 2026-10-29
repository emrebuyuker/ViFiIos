// Who receives a notification (NOTIFICATIONS.md §3.3): profile lookups in the Realtime Database, the campaign
// consent filter and the recipients' registered devices. Every function takes its Firebase handles as arguments, so
// tests run them against the emulators.
//
// Profiles live in RTDB `users/<uid>/profile`; `users` is indexed on `profile/universityId` (database.rules.json),
// so a segment reads one university's users and narrows the rest in memory. "Everyone" reads every profile — fine
// for the current user base; past ~10⁴ users switch to a precomputed audience summary (see NOTIFICATIONS.md §4).

import { matchesSegment } from './schema.js';

/** How many recipients' device lists / consent documents are read at once. */
const READ_CONCURRENCY = 20;
/** Documents per `getAll` call when reading consent. */
const GET_ALL_CHUNK = 300;

/** Every stored profile as `{ uid, profile }`. */
export async function loadAllProfiles(rtdb) {
  return profilesFrom(await rtdb.ref('users').once('value'));
}

/** The profiles of one university (indexed query), as `{ uid, profile }`. */
export async function loadUniversityProfiles(rtdb, universityId) {
  const snapshot = await rtdb.ref('users').orderByChild('profile/universityId').equalTo(universityId).once('value');
  return profilesFrom(snapshot);
}

/** The uids of a segment's members (university, then faculty / department / gender in memory). */
export async function loadSegmentUids(rtdb, segment) {
  const profiles = await loadUniversityProfiles(rtdb, segment.universityId);
  return profiles.filter(({ profile }) => matchesSegment(profile, segment)).map(({ uid }) => uid);
}

/**
 * The recipients of a fan-out notification: a test goes to its author only (no consent check — the admin asked for
 * the copy), a personal notice to its user, a segment to its members, "everyone" to every profile. Campaigns
 * (`promo`) then keep only users who opted in (`users/{uid}/settings/notifications.marketing == true`).
 *
 * @param {{ db: import('firebase-admin/firestore').Firestore, rtdb: import('firebase-admin/database').Database }} deps
 * @param {{ kind: string, audience: object, isTest?: boolean, createdBy?: string }} notification
 * @returns {Promise<string[]>} Distinct uids.
 */
export async function resolveRecipients({ db, rtdb }, { kind, audience, isTest = false, createdBy }) {
  if (isTest) {
    if (typeof createdBy !== 'string' || !createdBy) throw new Error('A test notification needs its author.');
    return [createdBy];
  }

  let uids;
  switch (audience?.scope) {
    case 'user':
      if (typeof audience.uid !== 'string' || !audience.uid) throw new Error('A personal notification needs a uid.');
      uids = [audience.uid];
      break;
    case 'segment':
      uids = await loadSegmentUids(rtdb, audience);
      break;
    case 'all':
      uids = (await loadAllProfiles(rtdb)).map(({ uid }) => uid);
      break;
    default:
      // `admins` is resolved by the automatic notifications (phase 3).
      throw new Error(`Unsupported audience scope: ${audience?.scope}`);
  }

  uids = [...new Set(uids)];
  return kind === 'promo' ? filterMarketingConsent(db, uids) : uids;
}

/** The uids that opted in to campaigns (`settings/notifications.marketing === true`); everyone else is dropped. */
export async function filterMarketingConsent(db, uids) {
  const consenting = [];
  for (const chunk of chunked(uids, GET_ALL_CHUNK)) {
    if (chunk.length === 0) continue;
    const refs = chunk.map((uid) => consentRef(db, uid));
    const snapshots = await db.getAll(...refs, { fieldMask: ['marketing'] });
    snapshots.forEach((snapshot, index) => {
      if (snapshot.exists && snapshot.get('marketing') === true) consenting.push(chunk[index]);
    });
  }
  return consenting;
}

/**
 * The recipients' registered devices, keyed by FCM token (a token registered twice — e.g. under an old and a new
 * installation id — is pushed once; every document holding it is listed so a dead token is pruned everywhere).
 *
 * @returns {Promise<Map<string, import('firebase-admin/firestore').DocumentReference[]>>}
 */
export async function loadDeviceTargets(db, uids) {
  const targets = new Map();
  await forEachLimited(uids, READ_CONCURRENCY, async (uid) => {
    const snapshot = await db.collection('users').doc(uid).collection('devices').select('token').get();
    for (const doc of snapshot.docs) {
      const token = doc.get('token');
      if (typeof token !== 'string' || !token) continue;
      const refs = targets.get(token) ?? [];
      refs.push(doc.ref);
      targets.set(token, refs);
    }
  });
  return targets;
}

/** All registered devices (every user) — the push reach of a broadcast that new clients know of. */
export async function countRegisteredDevices(db) {
  const snapshot = await db.collectionGroup('devices').count().get();
  return snapshot.data().count;
}

// MARK: helpers

function profilesFrom(snapshot) {
  const profiles = [];
  snapshot.forEach((child) => {
    const profile = child.child('profile').val();
    if (profile && typeof profile === 'object') profiles.push({ uid: child.key, profile });
  });
  return profiles;
}

function consentRef(db, uid) {
  return db.collection('users').doc(uid).collection('settings').doc('notifications');
}

export function chunked(items, size) {
  const chunks = [];
  for (let index = 0; index < items.length; index += size) chunks.push(items.slice(index, index + size));
  return chunks;
}

/** Runs `work` over `items` with at most `limit` calls in flight. */
export async function forEachLimited(items, limit, work) {
  let next = 0;
  const worker = async () => {
    while (next < items.length) {
      const item = items[next];
      next += 1;
      await work(item);
    }
  };
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
}

// Keeps each FCM token under one account (NOTIFICATIONS.md §3.5): a phone's token stays the same when another user
// signs in on it, and the previous user's device document may survive a failed sign-out delete. Without this the
// old account's personal notifications would still reach the phone.

import * as logger from 'firebase-functions/logger';

/**
 * `onDeviceWritten` (`users/{uid}/devices/{deviceId}`): when a token appears under `uid` (new document or changed
 * token), deletes the documents holding the same token under every OTHER uid. A document rewritten since the query
 * (its update time changed) is left alone.
 *
 * @param {{ db: import('firebase-admin/firestore').Firestore }} deps
 * @param {{ params: { uid: string }, data?: { before?: object, after?: object } }} event A Firestore `Change` event.
 * @returns {Promise<{ removed: number }>}
 */
export async function onDeviceWrittenHandler({ db }, event) {
  const after = event.data?.after;
  if (!after?.exists) return { removed: 0 };
  const token = after.get('token');
  if (typeof token !== 'string' || !token) return { removed: 0 };
  const before = event.data?.before;
  if (before?.exists && before.get('token') === token) return { removed: 0 };

  const { uid } = event.params;
  // Collection-group query on `devices.token` (field override in firestore.indexes.json).
  const matches = await db.collectionGroup('devices').where('token', '==', token).get();
  const stale = matches.docs.filter((doc) => {
    const owner = doc.ref.parent.parent;
    return owner !== null && owner.parent.id === 'users' && owner.id !== uid;
  });

  let removed = 0;
  await Promise.all(stale.map(async (doc) => {
    try {
      await doc.ref.delete({ lastUpdateTime: doc.updateTime });
      removed += 1;
    } catch (error) {
      logger.warn('Removing a duplicate device token failed', { path: doc.ref.path, error: error?.message });
    }
  }));
  return { removed };
}

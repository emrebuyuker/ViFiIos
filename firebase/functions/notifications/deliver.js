// Delivers a stored notification (`notifications/{id}`, NOTIFICATIONS.md §4 "Teslim"): the one path every sender
// shares — the admin composer now, the scheduled dispatcher and the automatic notifications later.
//
// - broadcast: one public `announcements/{id}` copy + a push to the `all` topic (also reaches 4.0.0 clients, which
//   subscribe to the topic but never register a token).
// - fanout: a copy in each recipient's `users/{uid}/inbox/{id}` + a push to their registered device tokens, in
//   batches of 500; tokens FCM reports as dead are pruned.

import { FieldValue } from 'firebase-admin/firestore';
import * as logger from 'firebase-functions/logger';
import { BROADCAST_TOPIC, buildPushMessage, toInboxItem } from './schema.js';
import { countRegisteredDevices, loadAllProfiles, loadDeviceTargets, resolveRecipients, chunked } from './audience.js';

/** FCM's limit for one `sendEachForMulticast` call. */
export const MULTICAST_LIMIT = 500;

/** FCM errors meaning the token will never work again; its device documents are deleted. */
export const PRUNABLE_TOKEN_ERRORS = Object.freeze([
  'messaging/registration-token-not-registered',
  'messaging/invalid-registration-token',
]);

/**
 * Delivers notification `notificationId`, which must be `status: 'sending'` — the caller claims it first (the
 * composer creates it that way; the scheduled dispatcher flips `scheduled → sending` in a transaction). Any other
 * status is left untouched, so a duplicate call never delivers twice.
 *
 * Ends in `sent` once the inbox copies are written (push failures only show in the stats) or `failed` (+ `error`)
 * when nothing could be delivered.
 *
 * @param {{ db: import('firebase-admin/firestore').Firestore, rtdb: import('firebase-admin/database').Database,
 *   messaging: { send: Function, sendEachForMulticast: Function } }} deps
 * @param {string} notificationId
 * @returns {Promise<{ status: string, recipients: number, pushTargets: number, pushSent: number, pushFailed: number }>}
 */
export async function deliverNotification(deps, notificationId) {
  const ref = deps.db.collection('notifications').doc(notificationId);
  const snapshot = await ref.get();
  if (!snapshot.exists) throw new Error(`Notification ${notificationId} does not exist.`);

  const notification = snapshot.data();
  if (notification.status !== 'sending') {
    return { status: notification.status, ...counters(notification.stats) };
  }

  let result;
  try {
    result = notification.delivery === 'broadcast'
      ? await broadcast(deps, notificationId, notification)
      : await fanout(deps, notificationId, notification);
  } catch (error) {
    logger.error('Notification delivery failed', { notificationId, error: error?.message ?? String(error) });
    await ref.update({ status: 'failed', error: String(error?.message ?? error).slice(0, 500) });
    return { status: 'failed', ...counters(notification.stats) };
  }

  await ref.update({
    status: 'sent',
    sentAt: FieldValue.serverTimestamp(),
    'stats.recipients': result.recipients,
    'stats.pushTargets': result.pushTargets,
    'stats.pushSent': result.pushSent,
    'stats.pushFailed': result.pushFailed,
  });
  return { status: 'sent', ...result };
}

async function broadcast({ db, rtdb, messaging }, notificationId, notification) {
  await db.collection('announcements').doc(notificationId)
    .set(toInboxItem(notification, { createdAt: FieldValue.serverTimestamp() }));

  // The topic reaches every install, including clients that never register a token, so its true reach is unknown:
  // `recipients` counts the profiles and `pushTargets` the registered devices (a lower bound). A topic send reports
  // no per-device outcome, so the registered devices count as sent (or failed) together.
  const [profiles, pushTargets] = await Promise.all([loadAllProfiles(rtdb), countRegisteredDevices(db)]);
  let pushSent = pushTargets;
  let pushFailed = 0;
  try {
    await messaging.send({ ...pushMessage(notificationId, notification), topic: BROADCAST_TOPIC });
  } catch (error) {
    logger.error('Broadcast push failed', { notificationId, error: error?.message ?? String(error) });
    pushSent = 0;
    pushFailed = pushTargets;
  }
  return { recipients: profiles.length, pushTargets, pushSent, pushFailed };
}

async function fanout(deps, notificationId, notification) {
  const { db, messaging } = deps;
  const uids = await resolveRecipients(deps, notification);

  // Inbox copies first: a push is only sent to users whose copy exists, so tapping it always finds the item.
  const item = toInboxItem(notification, { createdAt: FieldValue.serverTimestamp() });
  const writer = db.bulkWriter();
  const writes = uids.map((uid) => writer
    .set(db.collection('users').doc(uid).collection('inbox').doc(notificationId), item)
    .then(() => uid, (error) => {
      logger.warn('Inbox write failed', { notificationId, uid, error: error?.message });
      return null;
    }));
  await writer.close();
  const delivered = (await Promise.all(writes)).filter(Boolean);
  if (uids.length > 0 && delivered.length === 0) throw new Error('No inbox copy could be written.');

  const targets = await loadDeviceTargets(db, delivered);
  const tokens = [...targets.keys()];
  const message = pushMessage(notificationId, notification);
  const stale = [];
  let pushSent = 0;
  let pushFailed = 0;

  for (const batch of chunked(tokens, MULTICAST_LIMIT)) {
    let response;
    try {
      response = await messaging.sendEachForMulticast({ ...message, tokens: batch });
    } catch (error) {
      // A whole batch was refused (e.g. FCM unavailable): count it as failed and keep going.
      logger.error('Push batch failed', { notificationId, size: batch.length, error: error?.message ?? String(error) });
      pushFailed += batch.length;
      continue;
    }
    response.responses.forEach((outcome, index) => {
      if (outcome.success) {
        pushSent += 1;
        return;
      }
      pushFailed += 1;
      if (PRUNABLE_TOKEN_ERRORS.includes(outcome.error?.code)) stale.push(...targets.get(batch[index]));
    });
  }

  await pruneDevices(db, stale);
  return { recipients: delivered.length, pushTargets: tokens.length, pushSent, pushFailed };
}

/** Deletes the device documents of dead tokens; a failure is logged and never fails the delivery. */
async function pruneDevices(db, refs) {
  if (refs.length === 0) return;
  const writer = db.bulkWriter();
  const deletes = refs.map((ref) => writer.delete(ref).catch((error) => {
    logger.warn('Pruning a dead device token failed', { path: ref.path, error: error?.message });
  }));
  await writer.close();
  await Promise.all(deletes);
}

function pushMessage(notificationId, notification) {
  return buildPushMessage({
    notificationId,
    kind: notification.kind,
    title: notification.title,
    body: notification.body,
    imageUrl: notification.image?.url ?? null,
  });
}

function counters(stats = {}) {
  return {
    recipients: stats?.recipients ?? 0,
    pushTargets: stats?.pushTargets ?? 0,
    pushSent: stats?.pushSent ?? 0,
    pushFailed: stats?.pushFailed ?? 0,
  };
}

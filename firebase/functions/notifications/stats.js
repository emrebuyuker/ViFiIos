// Notification engagement statistics (NOTIFICATIONS.md §3.1, §3.6, §4): the `trackNotificationEvent` callable.
//
// The app reports two things per notification — `opened` (the inbox was opened from its push) and `actionTapped`
// (its button or card was used). Each is counted once per user, however often the app reports it, into
// `notifications/{id}.stats.opened` / `.actionTapped`, which the admin history shows.
//
// Dedupe + count in ONE atomic commit: a write batch that `create()`s the marker document
// `notifications/{id}/events/{uid}_{event}` and increments the counter. `create()` fails with ALREADY_EXISTS when the
// marker is there, and a failed batch applies nothing — so a repeat neither double-counts nor leaves a marker without
// its count (which a create-then-increment sequence would, if the process died between the two writes: the retry
// would then be deduped and the count lost for good). A batch also takes no read lock on the hot notification
// document, unlike a read-then-write transaction, so a burst of users opening one broadcast does not make
// transactions contend and retry; the counter is a plain server-side `increment`.
//
// Handlers take their dependencies (`db`) as the first argument, like `admin.js`, so tests run them against the
// Firestore emulator.

import { HttpsError } from 'firebase-functions/v2/https';
import { FieldValue } from 'firebase-admin/firestore';
import { NOTIFICATION_ID_PATTERN } from './schema.js';

/** The events a client may report; each has a matching `stats.<event>` counter. */
export const TRACKED_EVENTS = Object.freeze(['opened', 'actionTapped']);

/** Firestore's gRPC status codes this module reacts to. */
const ALREADY_EXISTS = 6;
const NOT_FOUND = 5;

/** The caller's uid when they are signed in with a +90 phone number (as `unlockExam`); otherwise `permission-denied`. */
export function requirePhoneUser(request) {
  const phoneNumber = request?.auth?.token?.phone_number ?? '';
  if (!request?.auth || !/^\+90[0-9]{10}$/.test(phoneNumber)) {
    throw new HttpsError('permission-denied', 'Bu işlem için giriş yapmış olman gerekiyor.');
  }
  return request.auth.uid;
}

/**
 * `trackNotificationEvent`: `{ notificationId, event }` → `{ counted }`, where `counted` is `false` for a repeat.
 *
 * The caller must be a recipient: the notification's own delivered copy has to exist — `users/{uid}/inbox/{id}` for a
 * fan-out, `announcements/{id}` for a broadcast. A notification that does not exist and one the caller never received
 * answer identically (`not-found`), so the callable cannot be used to find out which ids exist.
 *
 * @param {{ db: import('firebase-admin/firestore').Firestore }} deps
 * @returns {Promise<{ counted: boolean }>}
 */
export async function trackNotificationEventHandler(deps, request) {
  const uid = requirePhoneUser(request);
  const { notificationId, event } = request.data ?? {};
  if (typeof notificationId !== 'string' || !NOTIFICATION_ID_PATTERN.test(notificationId)) {
    throw new HttpsError('invalid-argument', 'Geçersiz bildirim kimliği.');
  }
  if (!TRACKED_EVENTS.includes(event)) {
    throw new HttpsError('invalid-argument', 'Geçersiz olay türü.');
  }

  const notificationRef = deps.db.collection('notifications').doc(notificationId);
  const notification = await notificationRef.get();
  if (!notification.exists || !(await isRecipient(deps.db, uid, notificationId, notification.get('delivery')))) {
    throw notFound();
  }

  const batch = deps.db.batch();
  batch.create(notificationRef.collection('events').doc(`${uid}_${event}`), {
    uid,
    event,
    createdAt: FieldValue.serverTimestamp(),
  });
  batch.update(notificationRef, { [`stats.${event}`]: FieldValue.increment(1) });
  try {
    await batch.commit();
  } catch (error) {
    // Already counted for this user: nothing was applied, and that is the answer.
    if (error?.code === ALREADY_EXISTS) return { counted: false };
    // The notification vanished between the read and the commit.
    if (error?.code === NOT_FOUND) throw notFound();
    throw error;
  }
  return { counted: true };
}

/** Whether `uid` was sent notification `notificationId`: a broadcast reaches everyone, a fan-out only its inboxes. */
async function isRecipient(db, uid, notificationId, delivery) {
  const copy = delivery === 'broadcast'
    ? db.collection('announcements').doc(notificationId)
    : db.collection('users').doc(uid).collection('inbox').doc(notificationId);
  return (await copy.get()).exists;
}

function notFound() {
  return new HttpsError('not-found', 'Bildirim bulunamadı.');
}

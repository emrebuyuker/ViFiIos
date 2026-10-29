// Scheduled notifications (NOTIFICATIONS.md §4, phase 3/G): the admin's `cancelNotification` callable and the
// `dispatchScheduledNotifications` job that runs every 5 minutes. Handlers take their dependencies (`db`, `rtdb`,
// `messaging`, `signImageUrl`, `now`) as the first argument, like `admin.js`, so tests run them against the emulators.
//
// Status machine of `notifications/{id}` (only Functions write it):
//
//   scheduled ──claim (dispatcher)──▶ sending ──deliverNotification──▶ sent | failed
//       │  ▲                             │
//       │  └─ quiet hours: re-deferred   └─ stuck past STUCK_SENDING_AFTER_MS: retried once, then failed
//       ├─ cancelNotification (admin) ──▶ canceled (+ canceledAt, canceledBy)
//       └─ expired before it could go out ──▶ canceled (+ error: 'expired')
//
// Every transition out of `scheduled` and every retry of a stuck `sending` is a transaction that re-reads the
// document, so overlapping dispatcher runs (or a cancel racing the dispatcher) act on a notification once.

import { HttpsError } from 'firebase-functions/v2/https';
import { FieldValue } from 'firebase-admin/firestore';
import * as logger from 'firebase-functions/logger';
import { NOTIFICATION_ID_PATTERN, quietHoursDeferral, respectsQuietHours } from './schema.js';
import { forEachLimited } from './audience.js';
import { deliverNotification } from './deliver.js';
import { requireAdmin } from './admin.js';

/** Due notifications handled per run, oldest first; the rest wait for the next run (5 minutes later). */
export const DISPATCH_BATCH = 25;
/** Notifications delivered at once by one run. */
export const DISPATCH_CONCURRENCY = 3;
/**
 * A run stops claiming new notifications after this long, so it never times out (the job's timeout is 540 s) with a
 * claimed notification left half-delivered. Unclaimed ones stay `scheduled` for the next run.
 */
export const DISPATCH_BUDGET_MS = 4 * 60 * 1000;
/** `sending` notifications inspected per run for stuck deliveries (only in-flight ones are ever `sending`). */
export const STUCK_SCAN_LIMIT = 100;
/**
 * A `sending` notification older than this is considered abandoned by a crashed or timed-out delivery. It must exceed
 * the longest timeout of any function that delivers (`sendNotification` 300 s, this job 540 s); raise it with them.
 */
export const STUCK_SENDING_AFTER_MS = 15 * 60 * 1000;
/** Delivery attempts per notification: the first plus one retry of a stuck delivery. */
export const MAX_DELIVERY_ATTEMPTS = 2;

/** `error` of a notification that expired before it could go out (`canceled`, never delivered). */
export const EXPIRED_ERROR = 'expired';
/** `error` of a notification whose delivery got stuck on every attempt. */
export const STUCK_ERROR = 'Delivery did not finish; gave up after the retry.';
/** `error` of a stuck notification that expired before it could be retried (it may have partly gone out). */
export const STUCK_EXPIRED_ERROR = 'Delivery did not finish and the notification expired before the retry.';

const NOT_CANCELABLE_MESSAGE = 'Bu bildirim gönderildiği için artık iptal edilemez.';

/**
 * `cancelNotification`: `{ notificationId }` → `{ notificationId, status: 'canceled' }`. Only a `scheduled`
 * notification can be canceled; anything else is `failed-precondition` (the app shows "not cancelable" and reloads),
 * an unknown id `not-found`. The check and the update are one transaction, so a cancel never slips past the
 * dispatcher's claim.
 */
export async function cancelNotificationHandler(deps, request) {
  const uid = requireAdmin(request);
  const notificationId = request.data?.notificationId;
  if (typeof notificationId !== 'string' || !NOTIFICATION_ID_PATTERN.test(notificationId)) {
    throw new HttpsError('invalid-argument', 'Geçersiz bildirim kimliği.');
  }

  const ref = deps.db.collection('notifications').doc(notificationId);
  await deps.db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(ref);
    if (!snapshot.exists) throw new HttpsError('not-found', 'Bildirim bulunamadı.');
    const status = snapshot.get('status');
    if (status === 'canceled') throw new HttpsError('failed-precondition', 'Bu bildirim zaten iptal edilmiş.');
    if (status !== 'scheduled') throw new HttpsError('failed-precondition', NOT_CANCELABLE_MESSAGE);
    transaction.update(ref, { status: 'canceled', canceledAt: FieldValue.serverTimestamp(), canceledBy: uid });
  });
  return { notificationId, status: 'canceled' };
}

/**
 * `dispatchScheduledNotifications` (every 5 minutes): first retries deliveries that got stuck in `sending`, then
 * delivers the due `scheduled` notifications (`scheduledAt <= now`, oldest first, at most `DISPATCH_BATCH`).
 * One notification's failure never stops the others.
 *
 * @returns {Promise<Record<string, number>>} How many notifications ended up where (for logs and tests).
 */
export async function dispatchScheduledNotificationsHandler(deps) {
  const now = deps.now();
  const startedAt = Date.now();
  const outOfTime = () => Date.now() - startedAt > DISPATCH_BUDGET_MS;
  const summary = { sent: 0, failed: 0, expired: 0, deferred: 0, skipped: 0, retried: 0, gaveUp: 0, errors: 0 };
  const count = (outcome) => {
    summary[outcome] += 1;
  };

  try {
    await recoverStuckDeliveries(deps, now, { count, outOfTime });
  } catch (error) {
    // Never let the recovery keep the due notifications from going out.
    logger.error('Scanning for stuck notifications failed', { error: error?.message ?? String(error) });
    count('errors');
  }

  const due = await deps.db.collection('notifications')
    .where('status', '==', 'scheduled')
    .where('scheduledAt', '<=', now)
    .orderBy('scheduledAt')
    .limit(DISPATCH_BATCH)
    .get();

  await forEachLimited(due.docs, DISPATCH_CONCURRENCY, async ({ id }) => {
    if (outOfTime()) return count('skipped');
    try {
      await dispatchOne(deps, id, now, count);
    } catch (error) {
      // A notification claimed before the failure stays `sending` and is retried by the stuck-delivery recovery.
      logger.error('Dispatching a scheduled notification failed', { notificationId: id, error: error?.message ?? String(error) });
      count('errors');
    }
  });

  if (Object.values(summary).some((value) => value > 0)) logger.info('Scheduled notifications dispatched', summary);
  return summary;
}

/**
 * Claims one due notification (`scheduled → sending`) and delivers it. In the same transaction it is instead left
 * alone (someone else claimed or canceled it: `skipped`), canceled as expired (`expired`) or — a campaign or "new
 * exam" notice that came due inside quiet hours, e.g. after an outage — moved to the end of them (`deferred`).
 */
async function dispatchOne(deps, notificationId, now, count) {
  const { db } = deps;
  const ref = db.collection('notifications').doc(notificationId);

  const claim = await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(ref);
    if (!snapshot.exists || snapshot.get('status') !== 'scheduled') return 'skipped';
    const notification = snapshot.data();
    const scheduledAt = millis(notification.scheduledAt);
    if (scheduledAt === null || scheduledAt > now.getTime()) return 'skipped';

    const expiresAt = millis(notification.expiresAt);
    if (expiresAt !== null && expiresAt <= now.getTime()) {
      transaction.update(ref, expiredUpdate());
      return 'expired';
    }

    const deferral = respectsQuietHours(notification) ? quietHoursDeferral(now) : null;
    if (deferral) {
      // It would expire before quiet hours end, so it can never go out.
      if (expiresAt !== null && expiresAt <= deferral.getTime()) {
        transaction.update(ref, expiredUpdate());
        return 'expired';
      }
      transaction.update(ref, { scheduledAt: deferral, deferredByQuietHours: true });
      return 'deferred';
    }

    // `sendingAt` is the claim's own time (not the run's start), so the stuck-delivery age is exact.
    transaction.update(ref, { status: 'sending', sendingAt: deps.now(), deliveryAttempts: 1 });
    return 'claimed';
  });

  if (claim !== 'claimed') return count(claim);
  return count(deliveredOutcome(await deliver(deps, notificationId)));
}

/**
 * Stuck-delivery recovery. A delivery that crashes or times out midway leaves its notification in `sending`
 * forever: `deliverNotification` only ever acts on `sending`, and nothing else moves it on. Once it has been
 * `sending` for longer than any delivering function can run (`STUCK_SENDING_AFTER_MS`), no live invocation still
 * owns it, so it is claimed again (fresh `sendingAt`, `deliveryAttempts + 1`) and delivered once more; after
 * `MAX_DELIVERY_ATTEMPTS` it ends as `failed`.
 *
 * Trade-off: the first attempt may have got partway. Inbox copies are keyed by the notification id, so a retry
 * rewrites them (no duplicate item, but its `createdAt` moves to the retry time and may show as unread again); the
 * pushes the first attempt already sent go out a second time. A single retry bounds that to one duplicate push per
 * device, which beats silently losing a notification most recipients never got. Marking it `failed` without a
 * retry would avoid duplicates but drop every recipient after the crash point.
 *
 * Age is measured from `sendingAt` (written when the dispatcher claims) or, for a notification created straight
 * into `sending` (the composer's "send now", automatic notices), from `createdAt`. One without either is never
 * touched: its age is unknown and it may still be in flight.
 */
async function recoverStuckDeliveries(deps, now, { count, outOfTime }) {
  const { db } = deps;
  const sending = await db.collection('notifications').where('status', '==', 'sending').limit(STUCK_SCAN_LIMIT).get();
  const cutoff = now.getTime() - STUCK_SENDING_AFTER_MS;
  const stuck = sending.docs.filter((snapshot) => {
    const since = startedSending(snapshot.data());
    if (since === null) logger.warn('A sending notification has no start time; leaving it alone', { notificationId: snapshot.id });
    return since !== null && since <= cutoff;
  });

  await forEachLimited(stuck, DISPATCH_CONCURRENCY, async ({ id }) => {
    if (outOfTime()) return count('skipped');
    try {
      await recoverOne(deps, id, now, cutoff, count);
    } catch (error) {
      logger.error('Recovering a stuck notification failed', { notificationId: id, error: error?.message ?? String(error) });
      count('errors');
    }
  });
}

/**
 * Re-claims one stuck notification and delivers it again, or gives up. The transaction re-checks that it is still
 * the same stuck delivery, so two overlapping runs retry it once. Counts `skipped` or `gaveUp`, or `retried` plus
 * the retry's delivery outcome (`sent` / `failed`).
 */
async function recoverOne(deps, notificationId, now, cutoff, count) {
  const { db } = deps;
  const ref = db.collection('notifications').doc(notificationId);

  const claim = await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(ref);
    if (!snapshot.exists || snapshot.get('status') !== 'sending') return 'skipped';
    const notification = snapshot.data();
    const since = startedSending(notification);
    if (since === null || since > cutoff) return 'skipped';

    const attempts = Number.isInteger(notification.deliveryAttempts) ? notification.deliveryAttempts : 1;
    if (attempts >= MAX_DELIVERY_ATTEMPTS) {
      transaction.update(ref, { status: 'failed', error: STUCK_ERROR });
      return 'gaveUp';
    }
    const expiresAt = millis(notification.expiresAt);
    if (expiresAt !== null && expiresAt <= now.getTime()) {
      transaction.update(ref, { status: 'failed', error: STUCK_EXPIRED_ERROR });
      return 'gaveUp';
    }
    transaction.update(ref, { sendingAt: deps.now(), deliveryAttempts: attempts + 1 });
    return 'claimed';
  });

  if (claim !== 'claimed') return count(claim);
  logger.warn('Retrying a stuck notification delivery', { notificationId });
  count('retried');
  return count(deliveredOutcome(await deliver(deps, notificationId)));
}

/** `deliverNotification`, or the test's stand-in (`deps.deliver`). */
function deliver(deps, notificationId) {
  return (deps.deliver ?? deliverNotification)(deps, notificationId);
}

function deliveredOutcome(result) {
  return result?.status === 'sent' ? 'sent' : 'failed';
}

function expiredUpdate() {
  return { status: 'canceled', error: EXPIRED_ERROR, canceledAt: FieldValue.serverTimestamp(), canceledBy: 'system' };
}

/** When the current delivery attempt started (epoch ms), or `null` when unknown. */
function startedSending(notification) {
  return millis(notification.sendingAt) ?? millis(notification.createdAt);
}

/** A Firestore `Timestamp` (or `Date`) as epoch ms; `null` for anything else. */
function millis(value) {
  if (value && typeof value.toMillis === 'function') return value.toMillis();
  if (value instanceof Date) return value.getTime();
  return null;
}

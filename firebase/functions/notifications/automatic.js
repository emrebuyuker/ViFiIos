// Automatic notifications (NOTIFICATIONS.md §1, §4 — phase 3/H), raised by the submission lifecycle instead of an
// admin's composer:
//
// - `onSubmissionModerated` (`submissions/{id}` updated, `pending → approved | rejected`):
//   - approved → a personal notice to the uploader ("Sınavın onaylandı", with the coins the approval credited, read
//     from the ledger entry `wallets/{ownerId}/ledger/{submissionId}`), delivered now; and, when the approval
//     published a new exam, a "new exam in your department" notice to that department's members (the uploader
//     excluded), at most one per department per Istanbul calendar day and held until 09:00 during quiet hours.
//   - rejected → a personal notice with the admin's reason when there is one, delivered now.
// - `onSubmissionCreated` (`submissions/{id}` created): a notice to every admin, delivered now.
//
// Every notification gets a deterministic id derived from the submission id and is recorded with `create()`, so a
// redelivered event never sends twice. They are `system` notices (never consent-filtered) recorded as
// `source: 'automatic'`, `createdBy: 'system'`, `trigger: …` and delivered through the shared `deliverNotification`;
// a deferred "new exam" notice is left `scheduled` for the scheduled dispatcher (phase 3/G).
//
// Handlers take their dependencies (`db`, `rtdb`, `messaging`, `auth`, `now`) as the first argument, like the
// composer's (`admin.js`); `index.js` wires the live ones.

import { FieldValue, Timestamp } from 'firebase-admin/firestore';
import * as logger from 'firebase-functions/logger';
import {
  BODY_LIMIT,
  NOTIFICATION_ID_PATTERN,
  PROFILE_ID_PATTERN,
  TITLE_LIMIT,
  audienceLabel,
  deliveryMode,
  quietHoursDeferral,
  respectsQuietHours,
} from './schema.js';
import { examAction } from './admin.js';
import { deliverNotification } from './deliver.js';

/** The `trigger` values of automatic notifications (NOTIFICATIONS.md §3.1). */
export const TRIGGERS = Object.freeze({
  submissionApproved: 'submissionApproved',
  submissionRejected: 'submissionRejected',
  newExam: 'newExam',
  newSubmission: 'newSubmission',
});

/** Server-only "new exam" daily limit per department (NOTIFICATIONS.md §3.6): `{ lastSentAt, notificationId }`. */
export const THROTTLE_COLLECTION = 'notificationThrottle';

// Türkiye stays on UTC+3 all year (as in schema.js), so its calendar day is the UTC day of the shifted instant.
const ISTANBUL_OFFSET_MS = 3 * 60 * 60 * 1000;
const ALREADY_EXISTS = 6;

/** The deterministic notification ids (each must fit `NOTIFICATION_ID_PATTERN`). */
export const automaticNotificationIds = (submissionId) => ({
  approved: `auto-approved-${submissionId}`,
  rejected: `auto-rejected-${submissionId}`,
  newExam: `auto-newexam-${submissionId}`,
  newSubmission: `auto-submission-${submissionId}`,
});

/**
 * `onSubmissionModerated`: reacts only to a real `pending → approved | rejected` transition; every other update
 * (re-saves, a later field change, a status that was not pending) does nothing.
 *
 * @param {{ db: import('firebase-admin/firestore').Firestore, now?: () => Date }} deps Plus what
 *   `deliverNotification` needs (`rtdb`, `messaging`).
 * @param {{ params: { id: string }, data?: { before?: object, after?: object } }} event A Firestore `Change` event.
 * @returns {Promise<{ owner?: string, department?: string, skipped?: string }>} What happened, for logs and tests.
 */
export async function onSubmissionModeratedHandler(deps, event) {
  const before = event.data?.before;
  const after = event.data?.after;
  const from = before?.exists ? before.get('status') : null;
  const to = after?.exists ? after.get('status') : null;
  if (from !== 'pending' || (to !== 'approved' && to !== 'rejected')) return { skipped: 'not-moderated' };

  const submissionId = event.params?.id;
  const ids = validIds(submissionId);
  if (!ids) {
    logger.warn('Submission id cannot name a notification; skipping', { submissionId });
    return { skipped: 'invalid-id' };
  }

  const submission = after.data();
  const ownerId = text(submission.ownerId);
  const outcome = {};
  const errors = [];

  if (to === 'rejected') {
    outcome.owner = ownerId ? await attempt(errors, 'rejected', () => notifyRejected(deps, ids, submission, ownerId)) : 'no-owner';
  } else {
    // The exam action (and the department notice) exist only when the approval published a new exam.
    const action = await publishedExamAction(deps.db, submission.publishedExamId);
    outcome.owner = ownerId
      ? await attempt(errors, 'approved', () => notifyApproved(deps, ids, submissionId, submission, ownerId, action))
      : 'no-owner';
    outcome.department = action
      ? await attempt(errors, 'newExam', () => notifyDepartment(deps, ids, action, ownerId))
      : 'no-new-exam';
  }

  if (errors.length > 0) throw errors[0];
  return outcome;
}

/**
 * `onSubmissionCreated`: tells every admin a submission is waiting for review. Not consent-filtered and never held
 * for quiet hours (NOTIFICATIONS.md §1).
 *
 * @param {{ db: import('firebase-admin/firestore').Firestore, auth: { listUsers: Function } }} deps Plus what
 *   `deliverNotification` needs.
 * @param {{ params: { id: string }, data?: object }} event A Firestore create event (`data` is the snapshot).
 */
export async function onSubmissionCreatedHandler(deps, event) {
  const snapshot = event.data;
  if (!snapshot?.exists || snapshot.get('status') !== 'pending') return { admins: 'not-pending' };
  const ids = validIds(event.params?.id);
  if (!ids) {
    logger.warn('Submission id cannot name a notification; skipping', { submissionId: event.params?.id });
    return { skipped: 'invalid-id' };
  }

  const submission = snapshot.data();
  const place = [text(submission.university), text(submission.department)].filter(Boolean).join(' › ');
  const body = place
    ? `${examLabel(submission)} (${place}) incelemeni bekliyor.`
    : `${examLabel(submission)} incelemeni bekliyor.`;
  const audience = { scope: 'admins' };
  const status = await recordAndDeliver(deps, ids.newSubmission, automaticRecord({
    trigger: TRIGGERS.newSubmission,
    title: 'Yeni sınav gönderimi',
    body,
    audience,
    label: audienceLabel(audience),
    status: 'sending',
  }));
  return { admins: status };
}

// MARK: - Personal notices

async function notifyApproved(deps, ids, submissionId, submission, ownerId, action) {
  const coins = await creditedCoins(deps.db, ownerId, submissionId);
  const first = action ? `${examLabel(submission)} arşive eklendi.` : `${examLabel(submission)} gönderin onaylandı.`;
  const second = coins ? `+${coins} coin hesabına yüklendi.` : 'Katkın için teşekkürler!';
  const audience = { scope: 'user', uid: ownerId };
  return recordAndDeliver(deps, ids.approved, automaticRecord({
    trigger: TRIGGERS.submissionApproved,
    title: 'Sınavın onaylandı',
    body: `${first} ${second}`,
    action,
    audience,
    label: audienceLabel(audience),
    status: 'sending',
  }));
}

async function notifyRejected(deps, ids, submission, ownerId) {
  const reason = text(submission.rejectionReason);
  const first = `${examLabel(submission)} gönderin onaylanmadı.`;
  const audience = { scope: 'user', uid: ownerId };
  return recordAndDeliver(deps, ids.rejected, automaticRecord({
    trigger: TRIGGERS.submissionRejected,
    title: 'Gönderin reddedildi',
    body: reason ? `${first} Sebep: ${reason}` : first,
    audience,
    label: audienceLabel(audience),
    status: 'sending',
  }));
}

/**
 * The approved coins: the ledger entry the approval wrote (`wallets/{ownerId}/ledger/{submissionId}`, keyed by the
 * submission id in the same batch as the status change). `null` when there is none (a zero-coin tier) or it cannot
 * be read — the notice then just leaves the amount out.
 */
async function creditedCoins(db, ownerId, submissionId) {
  try {
    const entry = await db.collection('wallets').doc(ownerId).collection('ledger').doc(submissionId).get();
    const amount = entry.exists ? entry.get('amount') : null;
    return Number.isInteger(amount) && amount > 0 ? amount : null;
  } catch (error) {
    logger.warn('Reading the approval ledger entry failed; notifying without the amount', {
      submissionId,
      error: error?.message ?? String(error),
    });
    return null;
  }
}

/** The "Sınava Git" action for the exam an approval published, or `null` (a duplicate, or not resolvable). */
async function publishedExamAction(db, publishedExamId) {
  const examId = text(publishedExamId);
  if (!examId || examId.includes('/')) return null;
  try {
    return await examAction(db, examId);
  } catch (error) {
    logger.warn('The published exam cannot be linked; notifying without the exam', {
      examId,
      error: error?.message ?? String(error),
    });
    return null;
  }
}

// MARK: - Department "new exam" notice

/**
 * The department's members (profile slugs from the exam's archive path), the uploader excluded. At most one per
 * department per Istanbul calendar day, counted on the day it is delivered (09:00 for one held over quiet hours), so
 * an approval at 23:00 and another at 10:00 the next morning still make only one. The throttle and the notification
 * record are written in one transaction, so concurrent approvals in the same department cannot both pass.
 */
async function notifyDepartment(deps, ids, action, ownerId) {
  const segment = departmentSegment(action.path);
  if (!segment) {
    logger.warn('The exam\'s department has no profile slugs; skipping the department notice', { examId: action.examId });
    return 'no-department';
  }

  const now = deps.now?.() ?? new Date();
  const trigger = TRIGGERS.newExam;
  const deferral = respectsQuietHours({ kind: 'system', trigger }) ? quietHoursDeferral(now) : null;
  const deliverAt = deferral ?? now;
  const status = deferral ? 'scheduled' : 'sending';
  const [universityName, facultyName, departmentName, courseName, examTitle] = action.names;

  const record = automaticRecord({
    trigger,
    title: 'Bölümüne yeni sınav eklendi',
    body: `${courseName} – ${examTitle} arşive eklendi. Hemen göz at!`,
    action,
    audience: segment,
    label: audienceLabel(segment, { university: universityName, faculty: facultyName, department: departmentName }),
    status,
    scheduledAt: deferral,
    deferredByQuietHours: deferral !== null,
    excludeUids: ownerId ? [ownerId] : [],
  });

  const { db } = deps;
  const throttleRef = db.collection(THROTTLE_COLLECTION).doc(throttleKey(segment));
  const ref = db.collection('notifications').doc(ids.newExam);
  const outcome = await db.runTransaction(async (transaction) => {
    const [throttle, existing] = await transaction.getAll(throttleRef, ref);
    if (existing.exists) return 'duplicate';
    const lastSentAt = throttle.exists ? throttle.get('lastSentAt') : null;
    if (lastSentAt instanceof Timestamp && sameIstanbulDay(lastSentAt.toDate(), deliverAt)) return 'throttled';
    transaction.set(throttleRef, { lastSentAt: Timestamp.fromDate(deliverAt), notificationId: ids.newExam });
    transaction.create(ref, record);
    return status;
  });

  if (outcome !== 'sending') return outcome;
  return (await deliverNotification(deps, ids.newExam)).status;
}

/**
 * The profile segment of an exam's department. Archive ids are composite (`uni`, `uni__fac`, `uni__fac__dep`, see
 * iOS `ArchivePublishPlan`), while profiles store each level's own slug, so the department id is split on `__`;
 * the university and faculty ids must agree with it. `null` when the path does not have that shape.
 */
export function departmentSegment(path) {
  if (!Array.isArray(path) || path.length < 3) return null;
  const [universityId, facultyPath, departmentPath] = path;
  const parts = typeof departmentPath === 'string' ? departmentPath.split('__') : [];
  if (parts.length !== 3 || !parts.every((part) => PROFILE_ID_PATTERN.test(part))) return null;
  if (universityId !== parts[0] || facultyPath !== `${parts[0]}__${parts[1]}`) return null;
  return { scope: 'segment', universityId: parts[0], facultyId: parts[1], departmentId: parts[2] };
}

/** `notificationThrottle/{universityId}__{facultyId}__{departmentId}`. */
export function throttleKey(segment) {
  return `${segment.universityId}__${segment.facultyId}__${segment.departmentId}`;
}

/** Whether two instants fall on the same calendar day in Türkiye. */
export function sameIstanbulDay(a, b) {
  return istanbulDay(a) === istanbulDay(b);
}

function istanbulDay(date) {
  return new Date(date.getTime() + ISTANBUL_OFFSET_MS).toISOString().slice(0, 10);
}

// MARK: - Recording

/** The `notifications/{id}` record of an automatic notice (NOTIFICATIONS.md §3.1). */
function automaticRecord({
  trigger, title, body, action = null, audience, label, status, scheduledAt = null, deferredByQuietHours = false, excludeUids = [],
}) {
  return {
    kind: 'system',
    title: clip(title, TITLE_LIMIT),
    body: clip(body, BODY_LIMIT),
    ...(action ? { action } : {}),
    audience,
    audienceLabel: label,
    // Recipients left out of the audience (the uploader of a "new exam"); `resolveRecipients` drops them.
    ...(excludeUids.length > 0 ? { excludeUids } : {}),
    delivery: deliveryMode({ kind: 'system', audience }),
    status,
    isTest: false,
    scheduledAt,
    deferredByQuietHours,
    expiresAt: null,
    source: 'automatic',
    trigger,
    createdBy: 'system',
    createdAt: FieldValue.serverTimestamp(),
    stats: { recipients: 0, pushTargets: 0, pushSent: 0, pushFailed: 0, opened: 0, actionTapped: 0 },
  };
}

/**
 * Creates the record and delivers it now. A record that already exists means this event was handled before (a
 * redelivery): nothing is sent again — one left in `sending` by a crash is the scheduled dispatcher's to recover.
 */
async function recordAndDeliver(deps, notificationId, record) {
  try {
    await deps.db.collection('notifications').doc(notificationId).create(record);
  } catch (error) {
    if (error?.code === ALREADY_EXISTS) return 'duplicate';
    throw error;
  }
  return (await deliverNotification(deps, notificationId)).status;
}

/** Runs one notice; a failure is logged and kept, so the other notice of the same event still goes out. */
async function attempt(errors, what, work) {
  try {
    return await work();
  } catch (error) {
    logger.error('Automatic notification failed', { what, error: error?.message ?? String(error) });
    errors.push(error);
    return 'error';
  }
}

// MARK: - Helpers

function validIds(submissionId) {
  if (typeof submissionId !== 'string' || !submissionId) return null;
  const ids = automaticNotificationIds(submissionId);
  return Object.values(ids).every((id) => NOTIFICATION_ID_PATTERN.test(id)) ? ids : null;
}

/** "Ders – Sınav" from the submission's display names. */
function examLabel(submission) {
  return [text(submission.lesson), text(submission.exam)].filter(Boolean).join(' – ') || 'Sınav';
}

function text(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function clip(value, limit) {
  const characters = [...value];
  return characters.length <= limit ? value : `${characters.slice(0, limit - 1).join('')}…`;
}

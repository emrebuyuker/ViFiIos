// The admin composer's callables (NOTIFICATIONS.md §4): `getNotificationAudience`, `previewNotification` and
// `sendNotification`. Handlers take their dependencies (`db`, `rtdb`, `messaging`, `now`) as the first argument, so
// tests run them against the emulators with a fake messaging client; `index.js` wires the live ones.

import { HttpsError } from 'firebase-functions/v2/https';
import { FieldValue } from 'firebase-admin/firestore';
import {
  ADMIN_KINDS,
  NotificationInputError,
  audienceLabel,
  buildAudienceFacets,
  deliveryMode,
  quietHoursDeferral,
  respectsQuietHours,
  validateAdminAudience,
  validateSendRequest,
} from './schema.js';
import {
  countRegisteredDevices,
  loadAllProfiles,
  loadDeviceTargets,
  loadUniversityProfiles,
  resolveRecipients,
} from './audience.js';
import { deliverNotification } from './deliver.js';

const EXAM_KINDS = Object.freeze(['JPG', 'PDF']);
/** The exam's ancestors, root → leaf: the denormalized id and name fields every published exam carries. */
const EXAM_ANCESTRY = Object.freeze([
  ['universityId', 'universityName'],
  ['facultyId', 'facultyName'],
  ['departmentId', 'departmentName'],
  ['courseId', 'courseName'],
]);

/** The caller's uid when they carry the `admin: true` custom claim (strict boolean); otherwise `permission-denied`. */
export function requireAdmin(request) {
  if (!request?.auth || request.auth.token?.admin !== true) {
    throw new HttpsError('permission-denied', 'Bu işlem için yetkin yok.');
  }
  return request.auth.uid;
}

// Every handler checks the caller before touching a dependency (the live ones are created on first access).

/** `getNotificationAudience`: the pickers' tree — names and counts only, never personal data. */
export async function getNotificationAudienceHandler(deps, request) {
  requireAdmin(request);
  const profiles = await loadAllProfiles(deps.rtdb);
  return buildAudienceFacets(profiles.map(({ profile }) => profile));
}

/** `previewNotification`: `{ kind, audience }` → `{ recipients, pushTargets }`, campaigns narrowed to opted-in users. */
export async function previewNotificationHandler(deps, request) {
  requireAdmin(request);
  const kind = request.data?.kind;
  if (!ADMIN_KINDS.includes(kind)) {
    throw new HttpsError('invalid-argument', 'Geçersiz bildirim türü.');
  }
  const audience = withInputErrors(() => validateAdminAudience(request.data?.audience));

  if (deliveryMode({ kind, audience }) === 'broadcast') {
    const [profiles, pushTargets] = await Promise.all([loadAllProfiles(deps.rtdb), countRegisteredDevices(deps.db)]);
    return { recipients: profiles.length, pushTargets };
  }
  const uids = await resolveRecipients(deps, { kind, audience });
  const targets = await loadDeviceTargets(deps.db, uids);
  return { recipients: uids.length, pushTargets: targets.size };
}

/**
 * `sendNotification`: validates the draft, records `notifications/{notificationId}` and either schedules it (a
 * future `scheduledAt`, or a campaign composed during quiet hours) or delivers it now. Idempotent per
 * `notificationId`: a retry returns the first call's current result and sends nothing.
 *
 * @returns {Promise<{ notificationId: string, status: string, scheduledAt: number|null, recipients: number }>}
 */
export async function sendNotificationHandler(deps, request) {
  const uid = requireAdmin(request);
  const now = deps.now();
  const input = withInputErrors(() => validateSendRequest(request.data, { now }));
  if (input.imagePath) {
    // Images arrive with phase 2 (upload, hosting and the notification service extension).
    throw new HttpsError('failed-precondition', 'Görsel henüz desteklenmiyor.');
  }

  const ref = deps.db.collection('notifications').doc(input.notificationId);
  const existing = await ref.get();
  if (existing.exists) return sendResult(existing);

  const action = input.action?.type === 'exam' ? await examAction(deps.db, input.action.examId) : input.action;
  const label = audienceLabel(input.audience, await segmentNames(deps.rtdb, input.audience));
  const { scheduledAt, deferredByQuietHours } = schedule(input, now);
  const status = scheduledAt ? 'scheduled' : 'sending';

  const notification = {
    kind: input.kind,
    title: input.title,
    body: input.body,
    ...(action ? { action } : {}),
    audience: input.audience,
    audienceLabel: label,
    delivery: deliveryMode(input),
    status,
    isTest: input.isTest,
    scheduledAt,
    deferredByQuietHours,
    expiresAt: input.expiresAt,
    source: 'admin',
    createdBy: uid,
    createdAt: FieldValue.serverTimestamp(),
    stats: { recipients: 0, pushTargets: 0, pushSent: 0, pushFailed: 0, opened: 0, actionTapped: 0 },
  };

  try {
    await ref.create(notification);
  } catch (error) {
    // A concurrent retry created it first: report that call's result instead of sending twice.
    if (error?.code === 6 /* ALREADY_EXISTS */) return sendResult(await ref.get());
    throw error;
  }

  if (status === 'scheduled') {
    // The scheduled dispatcher (phase 3) delivers it; segments resolve at delivery time.
    return { notificationId: input.notificationId, status, scheduledAt: scheduledAt.getTime(), recipients: 0 };
  }
  const result = await deliverNotification(deps, input.notificationId);
  return { notificationId: input.notificationId, status: result.status, scheduledAt: null, recipients: result.recipients };
}

/**
 * When the notification goes out: a test right away; otherwise at the admin's future `scheduledAt` (or now), pushed
 * to 09:00 when that falls in quiet hours and the kind respects them. `scheduledAt` is `null` for "deliver now".
 */
export function schedule(input, now) {
  if (input.isTest) return { scheduledAt: null, deferredByQuietHours: false };

  const requested = input.scheduledAt && input.scheduledAt.getTime() > now.getTime() ? input.scheduledAt : null;
  const deferral = respectsQuietHours(input) ? quietHoursDeferral(requested ?? now) : null;
  const scheduledAt = deferral ?? requested;
  if (deferral && input.expiresAt && input.expiresAt.getTime() <= deferral.getTime()) {
    throw new HttpsError('invalid-argument', 'Geçerlilik süresi sessiz saatler (22:00–09:00) bitmeden doluyor.');
  }
  return { scheduledAt, deferredByQuietHours: deferral !== null };
}

/**
 * The exam action the inbox card opens: the admin names `examId`; its archive path (ids + display names, as iOS
 * `ArchivePath`) and file kind come from the published `exams/{examId}`. Ancestors missing from the exam document
 * are read from the `catalogNodes` parent chain.
 */
export async function examAction(db, examId) {
  const snapshot = await db.collection('exams').doc(examId).get();
  const exam = snapshot.exists ? snapshot.data() : null;
  if (!exam || exam.status !== 'published') {
    throw new HttpsError('failed-precondition', 'Bağlanacak sınav bulunamadı ya da yayında değil.');
  }
  if (!EXAM_KINDS.includes(exam.kind)) {
    throw new HttpsError('failed-precondition', 'Bağlanacak sınavın dosya türü geçersiz.');
  }

  const ancestry = EXAM_ANCESTRY.map(([idField, nameField]) => ({ id: exam[idField], name: exam[nameField] }));
  const complete = ancestry.every(({ id, name }) => isText(id) && isText(name));
  const levels = complete ? ancestry : await catalogAncestry(db, exam.courseId);
  if (!levels) {
    throw new HttpsError('failed-precondition', 'Bağlanacak sınavın arşivdeki yeri bulunamadı.');
  }

  return {
    type: 'exam',
    examId,
    path: [...levels.map(({ id }) => id), examId],
    names: [...levels.map(({ name }) => name), isText(exam.title) ? exam.title : examId],
    examKind: exam.kind,
  };
}

/** university → course, walked up from the course's `catalogNodes` document; `null` if the chain is broken. */
async function catalogAncestry(db, courseId) {
  const levels = [];
  let nodeId = courseId;
  for (let depth = 0; depth < EXAM_ANCESTRY.length; depth += 1) {
    if (!isText(nodeId) || nodeId.includes('/')) return null;
    const node = await db.collection('catalogNodes').doc(nodeId).get();
    if (!node.exists || !isText(node.get('name'))) return null;
    levels.unshift({ id: node.id, name: node.get('name') });
    nodeId = node.get('parentId');
  }
  return nodeId === '' ? levels : null;
}

/** The picked university / faculty / department names for the history label (their most common spelling). */
async function segmentNames(rtdb, audience) {
  if (audience.scope !== 'segment') return {};
  const profiles = await loadUniversityProfiles(rtdb, audience.universityId);
  const { universities } = buildAudienceFacets(profiles.map(({ profile }) => profile));
  const university = universities.find(({ id }) => id === audience.universityId);
  const faculty = university?.faculties.find(({ id }) => id === audience.facultyId);
  const department = faculty?.departments.find(({ id }) => id === audience.departmentId);
  return { university: university?.name, faculty: faculty?.name, department: department?.name };
}

function sendResult(snapshot) {
  const data = snapshot.data();
  return {
    notificationId: snapshot.id,
    status: data.status,
    scheduledAt: data.scheduledAt?.toMillis?.() ?? null,
    recipients: data.stats?.recipients ?? 0,
  };
}

/** Runs a schema validation, turning its `NotificationInputError` into the callable's `invalid-argument`. */
function withInputErrors(validate) {
  try {
    return validate();
  } catch (error) {
    if (error instanceof NotificationInputError) throw new HttpsError('invalid-argument', error.message);
    throw error;
  }
}

function isText(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

// The notification contract (NOTIFICATIONS.md §3–§5): wire values, limits and the pure validation / shaping the
// notification Cloud Functions share. Free of Firebase so it is unit-tested directly
// (`tests/notificationSchema.test.mjs`).
//
// Keep in step with the iOS models — `ViFi/Core/Models/AppNotification.swift` and `NotificationAdmin.swift` — and
// the iOS parser (`NotificationPayloadParser.swift`): the same kinds, action types, limits and field names.

export const KINDS = Object.freeze(['general', 'promo', 'system']);
/** Kinds an admin may send from the composer; `system` is automatic only. */
export const ADMIN_KINDS = Object.freeze(['general', 'promo']);
export const ACTION_TYPES = Object.freeze(['location', 'exam', 'paywall', 'addExam', 'url']);
export const GENDERS = Object.freeze(['female', 'male']);

export const TITLE_LIMIT = 80;
export const BODY_LIMIT = 500;
export const URL_LIMIT = 500;
export const LOCATION_NAME_LIMIT = 120;
export const ADDRESS_LIMIT = 200;
export const PLACE_ID_LIMIT = 300;
export const EXAM_ID_LIMIT = 700;

/** A profile's canonical id (slug), as validated by `database.rules.json`. */
export const PROFILE_ID_PATTERN = /^[a-z0-9-]{1,140}$/;
/** Client UUIDs (lowercase) and Firestore auto-ids; becomes a document id, so nothing else is accepted. */
export const NOTIFICATION_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;

/**
 * Campaign images (NOTIFICATIONS.md §6): the admin's app uploads one JPEG per notification to
 * `notificationImages/<notificationId>.jpg` (Storage rule: admin create-only, `image/jpeg`, ≤ 1 MiB). The image is
 * never public: the inbox reads it by `storagePath` with the user's credentials, and the push carries a short-lived
 * signed URL minted at delivery time (never stored in Firestore).
 */
export const IMAGE_FOLDER = 'notificationImages';
export const IMAGE_CONTENT_TYPE = 'image/jpeg';
export const IMAGE_MAX_BYTES = 1024 * 1024;
/** The Storage path of a notification image; the file name is the notification id (`storage.rules` checks it). */
export const NOTIFICATION_IMAGE_PATTERN = /^notificationImages\/[A-Za-z0-9_-]{1,128}\.jpg$/;
/** How long the push's signed image URL stays valid: V4 signing's maximum, so a late-opened push still shows it. */
export const SIGNED_IMAGE_URL_TTL_MS = 7 * 24 * 60 * 60 * 1000;

/** Every installed app subscribes to this topic (also the 4.0.0 clients that never register a token). */
export const BROADCAST_TOPIC = 'all';

/** Campaigns and automatic "new exam" notifications are not delivered between 22:00 and 09:00 in Türkiye. */
export const QUIET_HOURS = Object.freeze({ startHour: 22, endHour: 9 });
// Türkiye has stayed on UTC+3 all year since 2016 (no daylight saving), so a fixed offset is exact.
const ISTANBUL_OFFSET_MS = 3 * 60 * 60 * 1000;
/** A schedule picked "now" is still accepted when it reaches the server a little later. */
export const SCHEDULE_GRACE_MS = 60 * 1000;

/** A request the caller must fix; the message is Turkish and shown to the admin as is. */
export class NotificationInputError extends Error {
  constructor(message) {
    super(message);
    this.name = 'NotificationInputError';
  }
}

/**
 * Validates and normalizes the `sendNotification` callable's input (an admin composing a notification).
 * Throws `NotificationInputError` on the first problem. Mirrors `NotificationDraft.validationIssue` on iOS; this is
 * the authority.
 *
 * @returns {{ notificationId: string, kind: string, title: string, body: string, action: object|null,
 *   imagePath: string|null, audience: object, scheduledAt: Date|null, expiresAt: Date|null, isTest: boolean }}
 */
export function validateSendRequest(data, { now = new Date() } = {}) {
  if (data === null || typeof data !== 'object') {
    throw new NotificationInputError('Bildirim bilgileri eksik.');
  }

  const notificationId = typeof data.notificationId === 'string' ? data.notificationId : '';
  if (!NOTIFICATION_ID_PATTERN.test(notificationId)) {
    throw new NotificationInputError('Geçersiz bildirim kimliği.');
  }

  const title = text(data.title);
  if (!title) throw new NotificationInputError('Başlık boş olamaz.');
  if ([...title].length > TITLE_LIMIT) {
    throw new NotificationInputError(`Başlık en fazla ${TITLE_LIMIT} karakter olabilir.`);
  }
  const body = text(data.body);
  if (!body) throw new NotificationInputError('Mesaj boş olamaz.');
  if ([...body].length > BODY_LIMIT) {
    throw new NotificationInputError(`Mesaj en fazla ${BODY_LIMIT} karakter olabilir.`);
  }

  const action = data.action == null ? null : validateAction(data.action);
  // A location is advertising whatever kind was picked, so it is always a campaign (consent-filtered).
  const kind = action?.type === 'location' ? 'promo' : data.kind;
  if (!ADMIN_KINDS.includes(kind)) {
    throw new NotificationInputError('Geçersiz bildirim türü.');
  }

  const audience = validateAdminAudience(data.audience);

  let imagePath = null;
  if (data.imagePath != null) {
    // Only this notification's own upload: an admin cannot point a notification at another one's image.
    if (data.imagePath !== notificationImagePath(notificationId) || !NOTIFICATION_IMAGE_PATTERN.test(data.imagePath)) {
      throw new NotificationInputError('Geçersiz görsel.');
    }
    imagePath = data.imagePath;
  }

  const scheduledAt = optionalDate(data.scheduledAt, 'Gönderim zamanı');
  if (scheduledAt && scheduledAt.getTime() < now.getTime() - SCHEDULE_GRACE_MS) {
    throw new NotificationInputError('Gönderim zamanı geçmişte olamaz.');
  }
  const expiresAt = optionalDate(data.expiresAt, 'Geçerlilik süresi');
  if (expiresAt && expiresAt.getTime() <= (scheduledAt ?? now).getTime()) {
    throw new NotificationInputError('Geçerlilik süresi gönderim zamanından sonra olmalı.');
  }

  if (data.isTest != null && typeof data.isTest !== 'boolean') {
    throw new NotificationInputError('Geçersiz test bilgisi.');
  }

  return { notificationId, kind, title, body, action, imagePath, audience, scheduledAt, expiresAt, isTest: data.isTest === true };
}

/** Where the image of notification `notificationId` is uploaded. */
export function notificationImagePath(notificationId) {
  return `${IMAGE_FOLDER}/${notificationId}.jpg`;
}

/**
 * Checks an uploaded notification image's Storage metadata (`{ contentType, size }`, `size` as GCS reports it: a
 * string or a number), or `null` when there is no such object. Throws `NotificationInputError` with what to fix.
 * The Storage rule already enforces the same on upload; this guards objects written around it (Admin SDK, console).
 */
export function validateImageObject(metadata) {
  if (!metadata) {
    throw new NotificationInputError('Görsel bulunamadı. Görseli yeniden seçip tekrar dene.');
  }
  const size = Number(metadata.size);
  if (metadata.contentType !== IMAGE_CONTENT_TYPE) {
    throw new NotificationInputError('Görsel JPEG biçiminde olmalı.');
  }
  if (!Number.isFinite(size) || size <= 0 || size > IMAGE_MAX_BYTES) {
    throw new NotificationInputError('Görsel en fazla 1 MB olabilir.');
  }
}

/** The audiences an admin may target from the composer: everyone, or a profile segment. */
export function validateAdminAudience(value) {
  if (value === null || typeof value !== 'object') {
    throw new NotificationInputError('Geçerli bir hedef kitle seç.');
  }
  if (value.scope === 'all') return { scope: 'all' };
  if (value.scope !== 'segment') {
    throw new NotificationInputError('Geçerli bir hedef kitle seç.');
  }

  const universityId = optionalProfileId(value.universityId);
  const facultyId = optionalProfileId(value.facultyId);
  const departmentId = optionalProfileId(value.departmentId);
  if (!universityId || (departmentId && !facultyId)) {
    throw new NotificationInputError('Geçerli bir hedef kitle seç.');
  }
  if (value.gender != null && !GENDERS.includes(value.gender)) {
    throw new NotificationInputError('Geçersiz cinsiyet seçimi.');
  }

  const segment = { scope: 'segment', universityId };
  if (facultyId) segment.facultyId = facultyId;
  if (departmentId) segment.departmentId = departmentId;
  if (value.gender != null) segment.gender = value.gender;
  return segment;
}

/** An admin-supplied action. The exam action carries only `examId`; the server fills its path from `exams/`. */
export function validateAction(value) {
  if (value === null || typeof value !== 'object' || !ACTION_TYPES.includes(value.type)) {
    throw new NotificationInputError('Geçersiz bildirim aksiyonu.');
  }
  switch (value.type) {
    case 'location': {
      const { latitude, longitude } = value;
      const name = text(value.name);
      const valid = isFiniteNumber(latitude) && latitude >= -90 && latitude <= 90
        && isFiniteNumber(longitude) && longitude >= -180 && longitude <= 180
        && name && [...name].length <= LOCATION_NAME_LIMIT;
      if (!valid) throw new NotificationInputError('Haritadan geçerli bir konum seç.');
      const location = { type: 'location', latitude, longitude, name };
      const address = text(value.address);
      if (address) location.address = clip(address, ADDRESS_LIMIT);
      const placeId = text(value.placeId);
      if (placeId) location.placeId = clip(placeId, PLACE_ID_LIMIT);
      return location;
    }
    case 'exam': {
      const examId = text(value.examId);
      if (!examId || examId.length > EXAM_ID_LIMIT || examId.includes('/')) {
        throw new NotificationInputError('Bağlanacak sınavı seç.');
      }
      return { type: 'exam', examId };
    }
    case 'url': {
      const url = text(value.url);
      if (!url || url.length > URL_LIMIT || !isHttpsURL(url)) {
        throw new NotificationInputError('Bağlantı https:// ile başlamalı.');
      }
      return { type: 'url', url };
    }
    default:
      return { type: value.type };
  }
}

/**
 * How a notification reaches its audience: `broadcast` (one public `announcements` doc + the `all` topic) or
 * `fanout` (a copy in each recipient's inbox + their device tokens). Campaigns always fan out: only users who opted
 * in may receive them, which neither a topic nor a public document can enforce. Tests go only to their author.
 */
export function deliveryMode({ kind, audience, isTest = false }) {
  if (isTest) return 'fanout';
  return audience.scope === 'all' && kind !== 'promo' ? 'broadcast' : 'fanout';
}

/** Whether a notification waits for the end of quiet hours (campaigns and automatic "new exam"; never tests). */
export function respectsQuietHours({ kind, trigger = null, isTest = false }) {
  if (isTest) return false;
  return kind === 'promo' || trigger === 'newExam';
}

/** The end of the quiet hours `date` falls in (09:00 in Türkiye), or `null` when `date` is outside them. */
export function quietHoursDeferral(date) {
  const local = new Date(date.getTime() + ISTANBUL_OFFSET_MS);
  const hour = local.getUTCHours();
  if (hour >= QUIET_HOURS.endHour && hour < QUIET_HOURS.startHour) return null;
  const dayShift = hour >= QUIET_HOURS.startHour ? 1 : 0;
  const endLocal = Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate() + dayShift, QUIET_HOURS.endHour);
  return new Date(endLocal - ISTANBUL_OFFSET_MS);
}

/** Whether a stored profile (RTDB `users/<uid>/profile`) belongs to a segment. */
export function matchesSegment(profile, segment) {
  if (!profile || profile.universityId !== segment.universityId) return false;
  if (segment.facultyId && profile.facultyId !== segment.facultyId) return false;
  if (segment.departmentId && profile.departmentId !== segment.departmentId) return false;
  if (segment.gender && profile.gender !== segment.gender) return false;
  return true;
}

/**
 * The audience pickers' tree (`getNotificationAudience`) from the stored profiles: only values someone has, with
 * counts per gender, sorted by name (Turkish collation). A custom (free-text) value may be spelled differently by
 * different users; the most common spelling of an id names it. Names and counts only — never personal data.
 */
export function buildAudienceFacets(profiles) {
  const universities = new Map();
  let total = 0;
  for (const profile of profiles) {
    if (!profile || !PROFILE_ID_PATTERN.test(profile.universityId ?? '')) continue;
    total += 1;
    const university = tally(universities, profile.universityId, profile.university, profile.gender);
    if (!PROFILE_ID_PATTERN.test(profile.facultyId ?? '')) continue;
    const faculty = tally(university.children, profile.facultyId, profile.faculty, profile.gender);
    if (!PROFILE_ID_PATTERN.test(profile.departmentId ?? '')) continue;
    tally(faculty.children, profile.departmentId, profile.department, profile.gender);
  }
  return {
    total,
    universities: finish(universities, (university) => ({
      faculties: finish(university.children, (faculty) => ({
        departments: finish(faculty.children, () => ({})),
      })),
    })),
  };
}

/** The history row's human-readable audience ("Üniv › Fakülte › Bölüm · Kadın"), from the picked nodes' names. */
export function audienceLabel(audience, names = {}) {
  switch (audience.scope) {
    case 'all':
      return 'Tüm kullanıcılar';
    case 'user':
      return 'Kişisel';
    case 'admins':
      return 'Adminler';
    case 'segment': {
      const parts = [
        names.university ?? audience.universityId,
        audience.facultyId ? names.faculty ?? audience.facultyId : null,
        audience.departmentId ? names.department ?? audience.departmentId : null,
      ].filter(Boolean);
      const gender = { female: 'Kadın', male: 'Erkek' }[audience.gender];
      return gender ? `${parts.join(' › ')} · ${gender}` : parts.join(' › ');
    }
    default:
      return '';
  }
}

/**
 * The copy written to `announcements/{id}` or `users/{uid}/inbox/{id}` (NOTIFICATIONS.md §3.2). `createdAt` is
 * passed in (a server timestamp sentinel in production) so the shape stays testable. The image travels as its
 * Storage path only (the app downloads it with the user's credentials); a signed URL never reaches Firestore.
 */
export function toInboxItem(notification, { createdAt }) {
  const item = { kind: notification.kind, title: notification.title, body: notification.body, createdAt };
  const storagePath = notification.image?.storagePath;
  if (typeof storagePath === 'string' && NOTIFICATION_IMAGE_PATTERN.test(storagePath)) item.image = { storagePath };
  if (notification.action) item.action = notification.action;
  if (notification.expiresAt) item.expiresAt = notification.expiresAt;
  return item;
}

/**
 * The platform-neutral FCM message for a notification (NOTIFICATIONS.md §5), without its target: the caller adds
 * `topic` or `tokens`. `data` values must be strings. `imageUrl` is the signed, short-lived URL of the image.
 *
 * `mutable-content` is always set: the iOS Notification Service Extension runs for every push to raise the app
 * icon badge by one (and attaches the image when there is one).
 */
export function buildPushMessage({ notificationId, kind, title, body, imageUrl = null }) {
  const message = {
    notification: { title, body },
    data: { notificationId, kind },
    apns: { payload: { aps: { sound: 'default', mutableContent: true } } },
    android: { priority: 'high', notification: { channelId: kind } },
  };
  if (imageUrl) {
    message.notification.imageUrl = imageUrl;
    // The iOS Notification Service Extension downloads and attaches it (`fcm_options.image`).
    message.apns.fcmOptions = { imageUrl };
    message.android.notification.imageUrl = imageUrl;
  }
  return message;
}

// MARK: helpers

function text(value) {
  return typeof value === 'string' ? value.trim() : '';
}

function clip(value, limit) {
  return [...value].slice(0, limit).join('');
}

function isFiniteNumber(value) {
  return typeof value === 'number' && Number.isFinite(value);
}

function isHttpsURL(value) {
  try {
    const url = new URL(value);
    return url.protocol === 'https:' && url.hostname.length > 0;
  } catch {
    return false;
  }
}

function optionalProfileId(value) {
  if (value == null || value === '') return null;
  if (typeof value !== 'string' || !PROFILE_ID_PATTERN.test(value)) {
    throw new NotificationInputError('Geçerli bir hedef kitle seç.');
  }
  return value;
}

function optionalDate(value, label) {
  if (value == null) return null;
  if (!isFiniteNumber(value) || value <= 0) {
    throw new NotificationInputError(`${label} geçersiz.`);
  }
  return new Date(value);
}

function tally(map, id, name, gender) {
  let node = map.get(id);
  if (!node) {
    node = { id, names: new Map(), count: 0, female: 0, male: 0, children: new Map() };
    map.set(id, node);
  }
  node.count += 1;
  if (gender === 'female') node.female += 1;
  if (gender === 'male') node.male += 1;
  const display = text(name);
  if (display) node.names.set(display, (node.names.get(display) ?? 0) + 1);
  return node;
}

function finish(map, extra) {
  return [...map.values()]
    .map((node) => ({
      id: node.id,
      name: mostCommonName(node.names) ?? node.id,
      count: node.count,
      female: node.female,
      male: node.male,
      ...extra(node),
    }))
    .sort((a, b) => a.name.localeCompare(b.name, 'tr'));
}

function mostCommonName(names) {
  let best = null;
  let bestCount = 0;
  for (const [name, count] of names) {
    // Ties keep the alphabetically first spelling, so the label is stable across calls.
    if (count > bestCount || (count === bestCount && best !== null && name.localeCompare(best, 'tr') < 0)) {
      best = name;
      bestCount = count;
    }
  }
  return best;
}

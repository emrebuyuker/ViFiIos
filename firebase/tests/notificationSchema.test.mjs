// The notification contract (`functions/notifications/schema.js`): admin input validation, delivery mode, quiet
// hours, segment matching, the audience tree and the inbox / push shapes. Pure — no emulator needed.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  IMAGE_MAX_BYTES,
  NotificationInputError,
  audienceLabel,
  buildAudienceFacets,
  buildPushMessage,
  deliveryMode,
  matchesSegment,
  notificationImagePath,
  quietHoursDeferral,
  respectsQuietHours,
  toInboxItem,
  validateImageObject,
  validateSendRequest,
} from '../functions/notifications/schema.js';

const NOW = new Date('2026-10-29T12:00:00Z'); // 15:00 in Türkiye

function request(overrides = {}) {
  return { notificationId: 'abc-123', kind: 'general', title: 'Başlık', body: 'Mesaj', audience: { scope: 'all' }, ...overrides };
}

function rejects(data, pattern) {
  assert.throws(() => validateSendRequest(data, { now: NOW }), (error) => {
    assert.ok(error instanceof NotificationInputError, `expected NotificationInputError, got ${error}`);
    if (pattern) assert.match(error.message, pattern);
    return true;
  });
}

test('a minimal request normalizes with defaults', () => {
  const result = validateSendRequest(request({ title: '  Başlık  ' }), { now: NOW });
  assert.deepEqual(result, {
    notificationId: 'abc-123',
    kind: 'general',
    title: 'Başlık',
    body: 'Mesaj',
    action: null,
    imagePath: null,
    audience: { scope: 'all' },
    scheduledAt: null,
    expiresAt: null,
    isTest: false,
  });
});

test('rejects missing or unsafe ids, empty or long text, and system/unknown kinds', () => {
  rejects(null);
  rejects(request({ notificationId: 'a/b' }), /kimliği/);
  rejects(request({ notificationId: '' }), /kimliği/);
  rejects(request({ title: '   ' }), /Başlık/);
  rejects(request({ title: 'a'.repeat(81) }), /80/);
  rejects(request({ body: '' }), /Mesaj/);
  rejects(request({ body: 'ç'.repeat(501) }), /500/);
  rejects(request({ kind: 'system' }), /türü/);
  rejects(request({ kind: 'spam' }), /türü/);
});

test('counts characters, not UTF-16 units, against the limits', () => {
  // 80 emoji = 160 UTF-16 units, still 80 characters.
  assert.doesNotThrow(() => validateSendRequest(request({ title: '🎉'.repeat(80) }), { now: NOW }));
});

test('segments need a valid university; a department needs its faculty; gender is female|male', () => {
  const segment = (fields) => request({ audience: { scope: 'segment', ...fields } });
  rejects(segment({}), /hedef kitle/);
  rejects(segment({ universityId: 'Boğaziçi' }), /hedef kitle/);
  rejects(segment({ universityId: 'u', departmentId: 'd' }), /hedef kitle/);
  rejects(segment({ universityId: 'u', gender: 'other' }), /cinsiyet/);
  rejects(request({ audience: { scope: 'user', uid: 'x' } }), /hedef kitle/);
  rejects(request({ audience: { scope: 'admins' } }), /hedef kitle/);

  const result = validateSendRequest(segment({ universityId: 'u', facultyId: 'f', departmentId: '', gender: 'female' }), { now: NOW });
  assert.deepEqual(result.audience, { scope: 'segment', universityId: 'u', facultyId: 'f', gender: 'female' });
});

test('a location action forces the campaign kind and is range-checked', () => {
  const location = { type: 'location', latitude: 41.08, longitude: 29.05, name: ' Kampüs Kafe ', address: 'Bebek' };
  const result = validateSendRequest(request({ kind: 'general', action: location }), { now: NOW });
  assert.equal(result.kind, 'promo');
  assert.deepEqual(result.action, { type: 'location', latitude: 41.08, longitude: 29.05, name: 'Kampüs Kafe', address: 'Bebek' });

  rejects(request({ action: { ...location, latitude: 91 } }), /konum/);
  rejects(request({ action: { ...location, longitude: '29' } }), /konum/);
  rejects(request({ action: { ...location, name: '' } }), /konum/);
});

test('exam, url and simple actions', () => {
  assert.deepEqual(validateSendRequest(request({ action: { type: 'exam', examId: ' u__f__d__c__vize ' } }), { now: NOW }).action,
    { type: 'exam', examId: 'u__f__d__c__vize' });
  rejects(request({ action: { type: 'exam', examId: 'a/b' } }), /sınavı/);
  rejects(request({ action: { type: 'url', url: 'http://example.com' } }), /https/);
  rejects(request({ action: { type: 'url', url: 'javascript:alert(1)' } }), /https/);
  assert.deepEqual(validateSendRequest(request({ action: { type: 'paywall', extra: 1 } }), { now: NOW }).action, { type: 'paywall' });
  rejects(request({ action: { type: 'poll' } }), /aksiyon/);
});

test('the image path must be this notification\'s own upload', () => {
  assert.equal(validateSendRequest(request({ imagePath: 'notificationImages/abc-123.jpg' }), { now: NOW }).imagePath,
    'notificationImages/abc-123.jpg');
  rejects(request({ imagePath: 'notificationImages/other.jpg' }), /görsel/);
  rejects(request({ imagePath: 'imagess/abc-123.jpg' }), /görsel/);
  rejects(request({ imagePath: 'notificationImages/abc-123.png' }), /görsel/);
  rejects(request({ imagePath: { storagePath: 'notificationImages/abc-123.jpg' } }), /görsel/);
  assert.equal(notificationImagePath('abc-123'), 'notificationImages/abc-123.jpg');
});

test('an uploaded image must exist, be a JPEG and be at most 1 MiB', () => {
  const invalid = (metadata, pattern) => assert.throws(() => validateImageObject(metadata), (error) => {
    assert.ok(error instanceof NotificationInputError);
    assert.match(error.message, pattern);
    return true;
  });
  // GCS reports `size` as a string.
  validateImageObject({ contentType: 'image/jpeg', size: String(IMAGE_MAX_BYTES) });
  validateImageObject({ contentType: 'image/jpeg', size: 1 });
  invalid(null, /bulunamadı/);
  invalid({ contentType: 'image/png', size: '10' }, /JPEG/);
  invalid({ contentType: 'image/jpeg; charset=binary', size: '10' }, /JPEG/);
  invalid({ contentType: 'image/jpeg', size: String(IMAGE_MAX_BYTES + 1) }, /1 MB/);
  invalid({ contentType: 'image/jpeg', size: '0' }, /1 MB/);
  invalid({ contentType: 'image/jpeg' }, /1 MB/);
});

test('schedule and expiry: epoch milliseconds, not in the past, expiry after delivery', () => {
  const inAnHour = NOW.getTime() + 3600_000;
  const result = validateSendRequest(request({ scheduledAt: inAnHour, expiresAt: inAnHour + 1 }), { now: NOW });
  assert.equal(result.scheduledAt.getTime(), inAnHour);
  // Within the minute of grace.
  assert.doesNotThrow(() => validateSendRequest(request({ scheduledAt: NOW.getTime() - 30_000 }), { now: NOW }));
  rejects(request({ scheduledAt: NOW.getTime() - 3600_000 }), /geçmişte/);
  rejects(request({ scheduledAt: '2026-10-30' }), /geçersiz/);
  rejects(request({ expiresAt: NOW.getTime() }), /Geçerlilik/);
  rejects(request({ scheduledAt: inAnHour, expiresAt: inAnHour - 1 }), /Geçerlilik/);
  rejects(request({ isTest: 'yes' }), /test/);
});

test('delivery: broadcast only for non-campaign all; campaigns and tests fan out', () => {
  assert.equal(deliveryMode({ kind: 'general', audience: { scope: 'all' } }), 'broadcast');
  assert.equal(deliveryMode({ kind: 'promo', audience: { scope: 'all' } }), 'fanout');
  assert.equal(deliveryMode({ kind: 'general', audience: { scope: 'segment', universityId: 'u' } }), 'fanout');
  assert.equal(deliveryMode({ kind: 'general', audience: { scope: 'all' }, isTest: true }), 'fanout');
});

test('quiet hours apply to campaigns and automatic new-exam notices, never to tests', () => {
  assert.equal(respectsQuietHours({ kind: 'promo' }), true);
  assert.equal(respectsQuietHours({ kind: 'system', trigger: 'newExam' }), true);
  assert.equal(respectsQuietHours({ kind: 'system', trigger: 'submissionApproved' }), false);
  assert.equal(respectsQuietHours({ kind: 'general' }), false);
  assert.equal(respectsQuietHours({ kind: 'promo', isTest: true }), false);
});

test('quiet hours defer 22:00–09:00 (Türkiye) to the next 09:00', () => {
  // 15:00 TR → not quiet.
  assert.equal(quietHoursDeferral(new Date('2026-10-29T12:00:00Z')), null);
  // 08:59 TR → not yet allowed; 09:00 TR → allowed.
  assert.equal(quietHoursDeferral(new Date('2026-10-29T05:59:00Z')).toISOString(), '2026-10-29T06:00:00.000Z');
  assert.equal(quietHoursDeferral(new Date('2026-10-29T06:00:00Z')), null);
  // 21:59 TR → allowed; 22:00 TR → next day 09:00 TR.
  assert.equal(quietHoursDeferral(new Date('2026-10-29T18:59:00Z')), null);
  assert.equal(quietHoursDeferral(new Date('2026-10-29T19:00:00Z')).toISOString(), '2026-10-30T06:00:00.000Z');
  // 02:00 TR on the 31st → 09:00 the same day; month and year ends roll over.
  assert.equal(quietHoursDeferral(new Date('2026-10-30T23:00:00Z')).toISOString(), '2026-10-31T06:00:00.000Z');
  assert.equal(quietHoursDeferral(new Date('2026-12-31T20:30:00Z')).toISOString(), '2027-01-01T06:00:00.000Z');
});

test('segment matching follows the most specific level and the gender', () => {
  const profile = { universityId: 'u', facultyId: 'f', departmentId: 'd', gender: 'female' };
  assert.equal(matchesSegment(profile, { universityId: 'u' }), true);
  assert.equal(matchesSegment(profile, { universityId: 'u', facultyId: 'f', departmentId: 'd', gender: 'female' }), true);
  assert.equal(matchesSegment(profile, { universityId: 'u', gender: 'male' }), false);
  assert.equal(matchesSegment(profile, { universityId: 'u', facultyId: 'x' }), false);
  assert.equal(matchesSegment(null, { universityId: 'u' }), false);
});

test('the audience tree lists only values users have, counted per gender, named by the most common spelling', () => {
  const facets = buildAudienceFacets([
    { universityId: 'sakarya-universitesi', university: 'Sakarya Üniversitesi', facultyId: 'muhendislik-fakultesi', faculty: 'Mühendislik Fakültesi', departmentId: 'makine-muhendisligi', department: 'Makine Mühendisliği', gender: 'male' },
    { universityId: 'sakarya-universitesi', university: 'SAKARYA ÜNİVERSİTESİ', facultyId: 'muhendislik-fakultesi', faculty: 'Mühendislik Fakültesi', departmentId: 'makine-muhendisligi', department: 'Makine Mühendisliği', gender: 'female' },
    { universityId: 'sakarya-universitesi', university: 'Sakarya Üniversitesi', facultyId: 'muhendislik-fakultesi', faculty: 'Mühendislik Fakültesi', departmentId: 'insaat-muhendisligi', department: 'İnşaat Mühendisliği', gender: 'female' },
    { universityId: 'bogazici-universitesi', university: 'Boğaziçi Üniversitesi', gender: 'female' },
    { universityId: 'Not A Slug', university: 'x' },
    null,
  ]);

  assert.equal(facets.total, 4);
  assert.deepEqual(facets.universities.map((u) => [u.id, u.name, u.count, u.female, u.male]), [
    ['bogazici-universitesi', 'Boğaziçi Üniversitesi', 1, 1, 0],
    ['sakarya-universitesi', 'Sakarya Üniversitesi', 3, 2, 1],
  ]);
  const sakarya = facets.universities[1];
  assert.deepEqual(sakarya.faculties.map((f) => [f.id, f.count]), [['muhendislik-fakultesi', 3]]);
  // Turkish collation: İnşaat before Makine.
  assert.deepEqual(sakarya.faculties[0].departments.map((d) => [d.id, d.count, d.female]), [
    ['insaat-muhendisligi', 1, 1],
    ['makine-muhendisligi', 2, 1],
  ]);
  assert.deepEqual(facets.universities[0].faculties, []);
  // Names and counts only — no personal data in the tree.
  assert.deepEqual(Object.keys(sakarya).sort(), ['count', 'faculties', 'female', 'id', 'male', 'name']);
  assert.deepEqual(Object.keys(sakarya.faculties[0].departments[0]).sort(), ['count', 'female', 'id', 'male', 'name']);
});

test('audience labels read naturally', () => {
  assert.equal(audienceLabel({ scope: 'all' }), 'Tüm kullanıcılar');
  assert.equal(
    audienceLabel({ scope: 'segment', universityId: 'u', facultyId: 'f', gender: 'female' }, { university: 'Üniv', faculty: 'Fakülte' }),
    'Üniv › Fakülte · Kadın',
  );
  assert.equal(audienceLabel({ scope: 'segment', universityId: 'u' }), 'u');
});

test('inbox copies and push messages carry exactly the contract fields', () => {
  const createdAt = 'SERVER_TIMESTAMP';
  assert.deepEqual(toInboxItem({ kind: 'general', title: 'T', body: 'B', audience: { scope: 'all' }, stats: {} }, { createdAt }),
    { kind: 'general', title: 'T', body: 'B', createdAt });

  const action = { type: 'paywall' };
  const expiresAt = new Date('2026-11-01T00:00:00Z');
  const image = { storagePath: 'notificationImages/n1.jpg' };
  // Only the storage path is copied: a URL (signed or not) never reaches the inbox documents.
  assert.deepEqual(toInboxItem({ kind: 'promo', title: 'T', body: 'B', action, expiresAt, image: { ...image, url: 'https://x/y.jpg' } }, { createdAt }),
    { kind: 'promo', title: 'T', body: 'B', createdAt, image, action, expiresAt });
  assert.deepEqual(toInboxItem({ kind: 'general', title: 'T', body: 'B', image: { storagePath: 'imagess/x.jpg' } }, { createdAt }),
    { kind: 'general', title: 'T', body: 'B', createdAt });

  // `mutable-content` on every push: the iOS service extension raises the icon badge even without an image.
  assert.deepEqual(buildPushMessage({ notificationId: 'n1', kind: 'general', title: 'T', body: 'B' }), {
    notification: { title: 'T', body: 'B' },
    data: { notificationId: 'n1', kind: 'general' },
    apns: { payload: { aps: { sound: 'default', mutableContent: true } } },
    android: { priority: 'high', notification: { channelId: 'general' } },
  });
  const withImage = buildPushMessage({ notificationId: 'n1', kind: 'promo', title: 'T', body: 'B', imageUrl: 'https://x/y.jpg' });
  assert.deepEqual(withImage, {
    notification: { title: 'T', body: 'B', imageUrl: 'https://x/y.jpg' },
    data: { notificationId: 'n1', kind: 'promo' },
    apns: { payload: { aps: { sound: 'default', mutableContent: true } }, fcmOptions: { imageUrl: 'https://x/y.jpg' } },
    android: { priority: 'high', notification: { channelId: 'promo', imageUrl: 'https://x/y.jpg' } },
  });
});

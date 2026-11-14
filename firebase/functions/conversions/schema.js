// The structured-exam contract (4.2.0, "soruları tek tek görme"): conversion jobs, published questions, question
// pools, the exam-title parser and the AI output schema shared by both model providers.
//
// This file is the AUTHORITATIVE side of the contract. The iOS read side mirrors it in
// `ViFi/Core/Models/ExamQuestion.swift`, `ExamConversion.swift`, `ViFi/Core/Utilities/ExamTitleParser.swift` and the
// parsers `ExamQuestionParser` / `ExamConversionParser`. A field, limit, status or id format changed here is changed
// there and in both test suites (`tests/conversionSchema.test.mjs`, `ExamTitleParserTests`, `ExamQuestionParserTests`).
//
// Firestore (`vifi` DB):
// - `examConversions/{jobId}`               admin read, server write — one AI job per exam (legacy) or submission.
// - `examConversions/{jobId}/questions/{n}` the draft questions; admins read and edit the editable fields.
// - `questions/{examId}-{nnn}`              the published, flat questions (+90 users and admins read; server writes).
// - `questionPools/{poolId}`                question-id pools for the practice mode (server writes).
// - `subjects/{subjectId}`                  country-wide course identities `{ name, aliases[] }` (server writes).
// - `questionPoolIndex/{subjectId}`         practice-mode pool counts per type and scope (server writes; PRACTICE MODE).
// - `aiUsage/{YYYY-MM}`                     monthly AI spend for the $50 cap (server only).
// Storage: `questionFigures/{jobId}/{nnn}-{k}[-r{revision}].jpg` (server writes, +90 users and admins get one file at a time).
//
// Pure — no Firebase imports, so everything here is unit-tested without the emulator.

import { slug } from './slug.js';

/** Bumped when the published question shape changes incompatibly; readers skip versions they do not know. */
export const QUESTION_SCHEMA_VERSION = 1;

/** The AI providers an admin can pick per action (owner decision K9, 13 Nov 2026). No server-side default. */
export const PROVIDERS = Object.freeze(['claude', 'gemini']);

/** Conversion job lifecycle. `published` and `discarded` are terminal. */
export const CONVERSION_STATUSES = Object.freeze(['queued', 'processing', 'ready', 'failed', 'published', 'discarded']);

/** Where a job's files came from. */
export const CONVERSION_SOURCES = Object.freeze(['legacy', 'submission']);

/**
 * Canonical exam types, parsed from archive titles (`parseExamTitle`); every Add Exam list entry (`ExamNameCatalog`
 * in the app) maps to one of them. A title that matches none parses to `examType: null` (it stays viewable, it just
 * joins no typed pool). Mirrors `ExamType` in the app.
 */
export const EXAM_TYPES = Object.freeze([
  'vize', 'final', 'butunleme', 'mazeret', 'kisa-sinav', 'yaz-okulu', 'ara-sinav',
  'tek-ders', 'ek-sinav', 'muafiyet', 'seviye-tespit', 'uygulama',
  'laboratuvar', 'odev', 'proje', 'calisma-sorulari', 'cozumlu-sorular',
]);

/** Study materials: archived and published with their `examType`, but never in a practice pool (owner decision K27). */
const NON_PRACTICE_EXAM_TYPES = new Set(['laboratuvar', 'odev', 'proje', 'calisma-sorulari', 'cozumlu-sorular']);

/**
 * The exam types that count for the future practice mode ("Sınava gir") and get `questionPools` entries — the single
 * source of truth on the server. Mirrors `ExamType.isPracticeEligible` in the app.
 */
export const PRACTICE_EXAM_TYPES = Object.freeze(EXAM_TYPES.filter((type) => !NON_PRACTICE_EXAM_TYPES.has(type)));

/**
 * The fixed exam-name list (owner decisions K27, K29; `ExamNameCatalog` in the app, same ids, names and order). The Add
 * Exam flow offers only these names, and an exam converted to the structured format gets its title from this list
 * (owner decision K28: `canonicalExamTitle` / `validateExamTitle`). `examType` is what `parseExamTitle` gives the name.
 */
export const EXAM_NAME_CATALOG = Object.freeze([
  { id: 'vize', name: 'VİZE', examType: 'vize' },
  { id: 'ara-sinav', name: 'ARA SINAV', examType: 'ara-sinav' },
  { id: 'final', name: 'FİNAL', examType: 'final' },
  { id: 'butunleme', name: 'BÜTÜNLEME', examType: 'butunleme' },
  { id: 'mazeret', name: 'MAZERET', examType: 'mazeret' },
  { id: 'tek-ders', name: 'TEK DERS', examType: 'tek-ders' },
  { id: 'ek-sinav', name: 'EK SINAV', examType: 'ek-sinav' },
  { id: 'yaz-okulu-vize', name: 'YAZ OKULU VİZE', examType: 'vize' },
  { id: 'yaz-okulu-ara-sinav', name: 'YAZ OKULU ARA SINAV', examType: 'ara-sinav' },
  { id: 'yaz-okulu-final', name: 'YAZ OKULU FİNAL', examType: 'final' },
  { id: 'kisa-sinav', name: 'KISA SINAV', examType: 'kisa-sinav' },
  { id: 'kisa-sinav-1', name: 'KISA SINAV 1', examType: 'kisa-sinav' },
  { id: 'kisa-sinav-2', name: 'KISA SINAV 2', examType: 'kisa-sinav' },
  { id: 'kisa-sinav-3', name: 'KISA SINAV 3', examType: 'kisa-sinav' },
  { id: 'muafiyet', name: 'MUAFİYET SINAVI', examType: 'muafiyet' },
  { id: 'seviye-tespit', name: 'SEVİYE TESPİT SINAVI', examType: 'seviye-tespit' },
  { id: 'uygulama', name: 'UYGULAMA SINAVI', examType: 'uygulama' },
  { id: 'laboratuvar', name: 'LABORATUVAR', examType: 'laboratuvar' },
  { id: 'odev', name: 'ÖDEV', examType: 'odev' },
  { id: 'proje', name: 'PROJE', examType: 'proje' },
  { id: 'calisma-sorulari', name: 'ÇALIŞMA SORULARI', examType: 'calisma-sorulari' },
  { id: 'cozumlu-sorular', name: 'ÇÖZÜMLÜ SORULAR', examType: 'cozumlu-sorular' },
].map((entry) => Object.freeze(entry)));

/** Practice-pool scopes (TODO-4.2.0 Ek C): country-wide, one university, one course. */
export const POOL_SCOPES = Object.freeze(['tr', 'university', 'course']);

/** Field limits (characters / counts). Firestore's 1 MiB document cap is far above these. */
export const LIMITS = Object.freeze({
  questionsPerExam: 150,
  label: 8,
  text: 8000,
  speech: 8000,
  choices: 10,
  choiceLabel: 4,
  choiceText: 2000,
  figuresPerQuestion: 6,
  answerText: 4000,
  solutionSteps: 30,
  solutionStep: 2000,
  topics: 8,
  topic: 60,
  unreadablePages: 200,
  unreadableReason: 300,
});

/** Document-id segment rules (Firestore ids; the same character set as the archive's composite slugs). */
export const ID_SEGMENT_PATTERN = /^[A-Za-z0-9_-]{1,700}$/;
export const JOB_ID_PATTERN = /^(exam|sub)-[A-Za-z0-9_-]{1,700}$/;

/**
 * Admin callables (europe-west1, admin claim required; Faz 1B implements, iOS `FirebaseExamConversionService` calls).
 * Every AI-running call carries `provider` ('claude' | 'gemini'); there is no default.
 *
 * - requestExamConversion      { examId, provider }                         → { jobId, status }   (legacy "Yeni yapıya geçir"; an active job is returned as is)
 * - requestBulkConversion      { courseId | departmentId, provider, dryRun } → { examCount, estimatedCostUsd, jobIds }
 * - regenerateExamConversion   { jobId, provider }                          → { status }           (K14 re-run / failed retry)
 * - regenerateDraftQuestion    { jobId, order, provider }                   → { status }           (K8)
 * - publishExamConversion      { jobId, subjectId?, newSubjectName?, examTitle? } → { examId, questionCount }  (2nd approval)
 * - discardExamConversion      { jobId }                                    → { status }           (K14 "Sınavı iptal et")
 * - updatePublishedQuestion    { questionId, text?, speech?, choices?, answer?, solution? } → { updatedAt }  (K15)
 * - regeneratePublishedQuestion { questionId, provider }                     → { status }           (K15)
 * Draft edits are direct Firestore updates (rules: content fields + editedBy/editedAt).
 *
 * First approval of a submission (admin client, `FirebaseModerationService.approve`, 4.2.0): ONE batch as today
 * (coins + ledger + Storage copy into imagess/ / pdfs/) but it writes NO catalogNodes / exams. The submission gets
 * `{ status: 'approved', tier, coins, reviewedAt, conversionProvider, publishPlan? }` where `publishPlan` (absent for a
 * duplicate) = `{ examId, universityId, facultyId, departmentId, courseId, nodesToCreate: [{ id, ...fields }],
 * childCountIncrements: [id], exam: { ...exam document fields incl. copied files } }` — the iOS `ArchivePublishPlan`,
 * executed by `publishExamConversion` on the second approval. `onSubmissionModerated` turns an approved submission
 * with `publishPlan` into job `sub-<id>`; a 4.1.0 approval (has `publishedExamId`, no plan) into job
 * `exam-<publishedExamId>` with `conversionProvider` absent → the job waits as `queued` without a provider until an
 * admin starts it (`regenerateExamConversion`).
 *
 * `publishPlan.mode` (owner decision K22, 13 Nov 2026): `'create'` (absent = create) publishes a new exam as above.
 * `'replace'` is a DUPLICATE submission (the archive already has the exam, `publishPlan.examId` = that existing exam):
 * the first approval still copies the files (`exam.files` = the copies) and starts job `sub-<id>` with the chosen
 * provider; `nodesToCreate` / `childCountIncrements` are empty. The second approval (`publishExamConversion`) creates
 * nothing in the catalog: it turns the EXISTING exam structured (legacy) or replaces its questions (already structured:
 * old `questions/<examId>-*` beyond the new count are deleted, ids keep their `<examId>-<nnn>` form), REPLACES the
 * exam's `files` with the submission's copies and deletes the previous files from Storage, updates pools/subjects, and
 * discards any other active job of that exam (`exam-<examId>`). A duplicate is approved with the same two buttons; the
 * admin app shows a "Bu sınav arşivde zaten yüklü" warning.
 *
 * Exam title (owner decisions K28, K29, 14 Nov 2026): a converted exam's title comes from `EXAM_NAME_CATALOG` as
 * `[<year> ]<list name>[ <1–99>]` (one 4-digit year; an academic-year range shows its second year). Job creation stores `placement.originalTitle` (the archive / submitted title)
 * and `placement.suggestedTitle` (`canonicalExamTitle(originalTitle)?.title`, `null` when no list name matches).
 * `publishExamConversion` uses `validateExamTitle(examTitle)` when the admin sent one, else the suggestion (a job
 * created before K28 has no `suggestedTitle` field: it is computed at publish); neither → `failed-precondition`
 * "Sınav adı listeden seçilmeli." The title is written to `exams/<id>.title` and `sortKey` (both are the title, as in
 * the migration); the exam document id never changes. Published questions' `examType` / `year` are parsed from it.
 * The submission's own `exam` text stays as submitted.
 *
 * Discard (K20): `discardExamConversion` on a `sub-` job deletes the files its first approval copied into imagess/ /
 * pdfs/ (never files an exam document still references). Subject change (K21): publishing with a different
 * `subjectId` / `newSubjectName` than the course's current one moves ALL of that course's published questions and
 * their pool entries to the new subject.
 */
export const CALLABLES = Object.freeze([
  'requestExamConversion',
  'requestBulkConversion',
  'regenerateExamConversion',
  'regenerateDraftQuestion',
  'publishExamConversion',
  'discardExamConversion',
  'updatePublishedQuestion',
  'regeneratePublishedQuestion',
]);

/**
 * PRACTICE MODE ("Sınava gir", in 4.2.0 — owner decisions P1–P5, 14 Nov 2026; plan: local TODO-SINAVA-GIR.md).
 *
 * Discovery (no callable): course catalog nodes carry `subjectId` (written by publish); the app reads
 * `questionPoolIndex/<subjectId>` = `{ subjectId, name, types: { <practice examType>: { tr: n, "u-<universityId>": n,
 * "c-<courseId>": n } }, updatedAt }` (1 read) to show the "Sınava gir" button (only when the course has ≥1 question in
 * any scope — data-driven, no remote switch) and the per-type / per-scope counts. Written by the server in the same
 * transaction as the pools (publish, K21 subject move, exam deletion cleanup; `conversions/poolIndex.js`); +90 users
 * and admins read it. Only scopes with n ≥ 1 are listed, a type without any is left out, and a subject without any
 * practice question has NO index document. `scripts/rebuild-pool-index.mjs` builds it once for earlier pools.
 * All scopes are shown even with a single question (P4).
 *
 * Questions are handed out by a callable so the free daily limit cannot be bypassed (europe-west1, signed-in +90
 * users; App Check as the other callables):
 * - nextPracticeQuestions { subjectId, examType, scope: 'course'|'university'|'tr', courseId?, universityId?,
 *     exclude: [questionId ≤ 300], count: 1…10 (default 1), subscriptionProof? }
 *   → { questions: [published question shape, Ek A, + `id` (`<examId>-<nnn>`), `examTitle`, `universityName` (both
 *       string | null); `updatedAt` as epoch ms], poolSize, remainingToday: number | null (null = Premium, unlimited),
 *       limitReached: bool }
 *   `courseId` is required for scope `course`, `universityId` for `university`; a non-practice `examType` (study
 *   materials, K27) or any other bad input is `invalid-argument`; a caller without a +90 number `permission-denied`.
 *   Random questions from the pool (all `__pN` parts; a missing pool = `poolSize: 0`) minus `exclude` (the session's
 *   seen ids); an exhausted pool returns [] (the app starts over by clearing `exclude`). Free users:
 *   PRACTICE_FREE_DAILY_LIMIT questions per Istanbul calendar day (00:00 Europe/Istanbul), counted per account in
 *   `users/<uid>/practice/daily` = `{ day: 'YYYY-MM-DD', count, seenToday: [ids], updatedAt }` (server-only write,
 *   owner read), counted per question delivered; a re-delivered id within the same day is not counted twice
 *   (`seenToday`, the day's last ≤ 50 ids) and is still delivered after the allowance is used up.
 *   `limitReached` = `remainingToday === 0` (no NEW question today → the app shows the paywall when it needs more).
 *   Premium: no counter. Unlimited session length (P2); no right/wrong tracking (P3).
 * - Premium proof: the subscription lives in StoreKit / Play, so the client sends `subscriptionProof`
 *   (`{ platform: 'ios', jws }` = the current StoreKit 2 entitlement's signed transaction; Android later
 *   `{ platform: 'android', purchaseToken, productId }`). The server verifies it (appStore.js
 *   `verifySubscriptionTransaction`; Android is not verified yet and counts as free), checks product ∈ subscription
 *   products, not revoked, `expiresDate` > now, and caches the result in `subscriptions/<uid>` = `{ platform,
 *   productId, originalTransactionId, expiresAt, verifiedAt }` so later calls skip re-verification (and the proof)
 *   until `expiresAt`. No proof / invalid proof / store error → free rules (never an error).
 * Account deletion removes `users/<uid>/practice/*` (with `users/<uid>`) and `subscriptions/<uid>`.
 */
export const PRACTICE_FREE_DAILY_LIMIT = 5;
export const PRACTICE_MAX_BATCH = 10;
export const PRACTICE_MAX_EXCLUDE = 300;

// MARK: - Ids and paths

/** `exam-<examId>` for a legacy exam, `sub-<submissionId>` for a user submission. */
export function conversionJobId(source) {
  if (source?.type === 'legacy' && ID_SEGMENT_PATTERN.test(source.examId ?? '')) return `exam-${source.examId}`;
  if (source?.type === 'submission' && ID_SEGMENT_PATTERN.test(source.submissionId ?? '')) {
    return `sub-${source.submissionId}`;
  }
  throw new ConversionSchemaError('invalid-source', 'A job source needs type legacy+examId or submission+submissionId');
}

/** Zero-padded 1-based position (`001`); the draft question's document id and the published id's suffix. */
export function questionOrderKey(order) {
  if (!Number.isInteger(order) || order < 1 || order > 999) {
    throw new ConversionSchemaError('invalid-order', `Question order must be 1…999, got ${order}`);
  }
  return String(order).padStart(3, '0');
}

/** The permanent published id: `<examId>-<nnn>`. Bookmarks / progress will hang off it, so it never changes. */
export function publishedQuestionId(examId, order) {
  if (!ID_SEGMENT_PATTERN.test(examId ?? '')) throw new ConversionSchemaError('invalid-exam-id', 'Bad exam id');
  return `${examId}-${questionOrderKey(order)}`;
}

/**
 * A cropped figure: `questionFigures/<jobId>/<nnn>-<k>.jpg`, `k` 1-based within the question. A regenerated question
 * writes `<nnn>-<k>-r<revision>.jpg` (revision ≥ 2; absent or 1 = no suffix) so URL-keyed client caches never serve
 * the superseded image.
 */
export function figureStoragePath(jobId, order, index, revision) {
  if (!JOB_ID_PATTERN.test(jobId ?? '')) throw new ConversionSchemaError('invalid-job-id', 'Bad job id');
  if (!Number.isInteger(index) || index < 1 || index > LIMITS.figuresPerQuestion) {
    throw new ConversionSchemaError('invalid-figure-index', `Figure index must be 1…${LIMITS.figuresPerQuestion}`);
  }
  if (revision !== undefined && (!Number.isInteger(revision) || revision < 1)) {
    throw new ConversionSchemaError('invalid-figure-revision', 'Figure revision must be a positive integer');
  }
  const suffix = revision > 1 ? `-r${revision}` : '';
  return `questionFigures/${jobId}/${questionOrderKey(order)}-${index}${suffix}.jpg`;
}

/**
 * `questionPools/<subjectId>__<examType>__<scope>`, scope `tr` | `u-<universityId>` | `c-<courseId>`. A pool past
 * ~15k ids is continued in a `__p2` (… `__pN`) document; `part` 1 has no suffix. Only practice-eligible exam types
 * (`PRACTICE_EXAM_TYPES`) have pools.
 */
export function questionPoolId({ subjectId, examType, scope, universityId, courseId, part = 1 }) {
  if (!ID_SEGMENT_PATTERN.test(subjectId ?? '')) throw new ConversionSchemaError('invalid-pool', 'Bad subject id');
  if (!PRACTICE_EXAM_TYPES.includes(examType)) throw new ConversionSchemaError('invalid-pool', 'Bad exam type');
  let scopeKey;
  if (scope === 'tr') scopeKey = 'tr';
  else if (scope === 'university' && ID_SEGMENT_PATTERN.test(universityId ?? '')) scopeKey = `u-${universityId}`;
  else if (scope === 'course' && ID_SEGMENT_PATTERN.test(courseId ?? '')) scopeKey = `c-${courseId}`;
  else throw new ConversionSchemaError('invalid-pool', 'Bad pool scope');
  if (!Number.isInteger(part) || part < 1) throw new ConversionSchemaError('invalid-pool', 'Bad pool part');
  return `${subjectId}__${examType}__${scopeKey}${part > 1 ? `__p${part}` : ''}`;
}

/** The monthly AI-usage document id for the $50 cap: `YYYY-MM` in Europe/Istanbul (UTC+3 all year). */
export function usageMonthKey(date) {
  const shifted = new Date(date.getTime() + 3 * 60 * 60 * 1000);
  return `${shifted.getUTCFullYear()}-${String(shifted.getUTCMonth() + 1).padStart(2, '0')}`;
}

// MARK: - Exam title → type + year

// Checked in this order; the first hit wins, needles match whole slug words only. Study materials come first
// ("FİNAL ÇALIŞMA SORULARI" is study material), then the specific exam kinds, then vize/final (so "2019 YAZ OKULU
// FİNAL" is a final, "MAZERET VİZE" a make-up) and plain "YAZ OKULU" last.
const TYPE_KEYS = Object.freeze([
  ['calisma-sorulari', ['calisma-sorulari']],
  ['cozumlu-sorular', ['cozumlu-sorular']],
  ['laboratuvar', ['laboratuvar', 'laboratuar', 'lab']],
  ['odev', ['odev', 'odevi', 'odevler']],
  ['proje', ['proje', 'projesi']],
  ['butunleme', ['butunleme']],
  ['mazeret', ['mazeret']],
  ['tek-ders', ['tek-ders']],
  ['ek-sinav', ['ek-sinav', 'ek-sinavi']],
  ['muafiyet', ['muafiyet']],
  ['seviye-tespit', ['seviye-tespit']],
  ['uygulama', ['uygulama-sinavi', 'uygulama-sinav']],
  ['kisa-sinav', ['kisa-sinav', 'kisa-sinavlari', 'quiz']],
  ['ara-sinav', ['ara-sinav', 'arasinav']],
  ['vize', ['vize']],
  ['final', ['final']],
  ['yaz-okulu', ['yaz-okulu']],
]);

/**
 * Splits an archive exam title ("2019 FİNAL", "2017-2018 VİZE", "KISA SINAV 3") into `{ examType, year }`. The
 * year is the first 19xx/20xx number (an academic-year range gives its second year, K29); either part is `null` when
 * absent. Mirrors `ExamTitleParser.parse` in the app.
 */
export function parseExamTitle(title) {
  const key = slug(String(title ?? ''));
  const tokens = key.split('-');
  const yearToken = yearOf(tokens);
  const padded = `-${key}-`;
  const match = TYPE_KEYS.find(([, needles]) => needles.some((needle) => padded.includes(`-${needle}-`)));
  return { examType: match ? match[0] : null, year: yearToken ? Number(yearToken) : null };
}

/**
 * The exam's year word: the first 19xx/20xx word, or the SECOND year of an academic-year range ("2017-2018" → 2018,
 * owner decision K29); `null` when there is none.
 */
function yearOf(tokens) {
  const index = tokens.findIndex((token) => /^(19|20)\d{2}$/.test(token));
  if (index < 0) return null;
  const next = tokens[index + 1];
  return next !== undefined && /^(19|20)\d{2}$/.test(next) ? next : tokens[index];
}

// MARK: - Exam title → list title (K28)

const ENTRY_BY_ID = Object.freeze(Object.fromEntries(EXAM_NAME_CATALOG.map((entry) => [entry.id, entry])));
/** List entry per base exam type; summer-school vize / ara sınav / final have their own entries. */
const ENTRY_BY_TYPE = Object.freeze(Object.fromEntries(
  EXAM_NAME_CATALOG.filter((entry) => !entry.id.startsWith('yaz-okulu-') && !/^kisa-sinav-\d$/.test(entry.id))
    .map((entry) => [entry.examType, entry]),
));
const SUMMER_ENTRY_BY_TYPE = Object.freeze(Object.fromEntries(
  EXAM_NAME_CATALOG.filter((entry) => entry.id.startsWith('yaz-okulu-')).map((entry) => [entry.examType, entry]),
));
const LIST_NAME_ALTERNATION = EXAM_NAME_CATALOG.map((entry) => entry.name)
  .sort((a, b) => b.length - a.length)
  .join('|');
const LIST_TITLE_PATTERN = new RegExp(`^(?:((?:19|20)\\d{2}) )?(${LIST_NAME_ALTERNATION})(?: ([1-9]\\d?))?$`, 'u');

/** Index of the first occurrence of `needle` (slug words) in `tokens`, or -1. */
function indexOfWords(tokens, needle) {
  const words = needle.split('-');
  for (let index = 0; index + words.length <= tokens.length; index += 1) {
    if (words.every((word, offset) => tokens[index + offset] === word)) return index;
  }
  return -1;
}

/**
 * The list title an archive title converts to (owner decision K28): `{ title, entryId, examType }`, or `null` when no
 * list name matches. Title = year part + list name + sequence number:
 * - year: the first 19xx/20xx word; an academic-year range ("2017-2018") gives its SECOND year (K29);
 * - list name: the base type by `parseExamTitle`'s priority without plain "yaz okulu" (study materials first, so
 *   "FİNAL ÇALIŞMA SORULARI" → ÇALIŞMA SORULARI; LAB → LABORATUVAR, QUIZ → KISA SINAV …); a title that also says
 *   "yaz okulu" maps vize / ara sınav / final to the YAZ OKULU entries. "YAZ OKULU" alone has no base type → `null`;
 * - sequence number: a 1–99 number written right after the matched type words ("QUIZ 5" → "KISA SINAV 5");
 *   a kısa sınav numbered 1–3 takes the list's own "KISA SINAV 1/2/3" name instead (K29).
 * Every other word (course names, "CEVAPLI" …) is dropped. Mirrors `ExamTitleParser.canonicalTitle` in the app.
 */
export function canonicalExamTitle(title) {
  const tokens = slug(String(title ?? '')).split('-');
  let match = null;
  for (const [type, needles] of TYPE_KEYS) {
    if (type === 'yaz-okulu') continue;
    for (const needle of needles) {
      const index = indexOfWords(tokens, needle);
      if (index >= 0) {
        match = { type, end: index + needle.split('-').length };
        break;
      }
    }
    if (match) break;
  }
  if (!match) return null;
  const summer = indexOfWords(tokens, 'yaz-okulu') >= 0;
  const entry = (summer ? SUMMER_ENTRY_BY_TYPE[match.type] : null) ?? ENTRY_BY_TYPE[match.type];
  if (!entry) return null;

  const year = yearOf(tokens);
  const after = tokens[match.end];
  let number = after !== undefined && /^\d{1,2}$/.test(after) && Number(after) >= 1 ? Number(after) : null;
  // "KISA SINAV 1/2/3" are list names of their own (K29); a higher quiz number stays a sequence number.
  const numbered = number !== null && entry.id === 'kisa-sinav' ? ENTRY_BY_ID[`kisa-sinav-${number}`] : undefined;
  const finalEntry = numbered ?? entry;
  if (numbered) number = null;
  return {
    title: [year, finalEntry.name, number].filter((part) => part !== null).join(' '),
    entryId: finalEntry.id,
    examType: finalEntry.examType,
  };
}

/**
 * Splits a list title (`[<year> ]<list name>[ <1–99>]`, year = one 19xx/20xx word, K29) into `{ year, entryId,
 * number, title }`; `null` for anything else. Whitespace is trimmed and collapsed; the name must be written exactly
 * as in the list (Turkish uppercase). "KISA SINAV 2" is the list name itself; a numbered list name takes no number.
 */
export function parseListTitle(title) {
  if (typeof title !== 'string') return null;
  const normalized = title.normalize('NFC').trim().replace(/\s+/gu, ' ');
  const match = LIST_TITLE_PATTERN.exec(normalized);
  if (!match) return null;
  const entry = EXAM_NAME_CATALOG.find((candidate) => candidate.name === match[2]);
  if (match[3] && /^kisa-sinav-\d$/.test(entry.id)) return null;
  return { year: match[1] ? Number(match[1]) : null, entryId: entry.id, number: match[3] ? Number(match[3]) : null, title: normalized };
}

/** The normalised list title, or `ConversionSchemaError('invalid-exam-title')` (K28: only list names are accepted). */
export function validateExamTitle(title) {
  const parsed = parseListTitle(title);
  if (!parsed) throw new ConversionSchemaError('invalid-exam-title', 'Sınav adı listeden seçilmeli.');
  return parsed.title;
}

// MARK: - AI output (both providers)

/**
 * The JSON schema both models are asked to fill (TODO-4.2.0 Ek B). Boxes are normalised to 0…1000 with a top-left
 * origin; `page` is 1-based over the exam's files in order (a PDF's pages continue the count).
 */
export const MODEL_OUTPUT_SCHEMA = Object.freeze({
  type: 'object',
  required: ['questions', 'unreadable'],
  properties: {
    questions: {
      type: 'array',
      items: {
        type: 'object',
        required: ['label', 'text', 'speech', 'choices', 'figures', 'answer', 'solution', 'topics', 'difficulty', 'confidence'],
        properties: {
          label: { type: 'string' },
          text: { type: 'string' },
          speech: { type: 'string' },
          choices: {
            type: 'array',
            items: { type: 'object', required: ['label', 'text'], properties: { label: { type: 'string' }, text: { type: 'string' } } },
          },
          figures: {
            type: 'array',
            items: {
              type: 'object',
              required: ['page', 'box'],
              properties: { page: { type: 'integer' }, box: { type: 'array', items: { type: 'number' } } },
            },
          },
          answer: {
            type: 'object',
            required: ['text'],
            properties: { text: { type: 'string' }, choice: { type: 'string' }, speech: { type: 'string' } },
          },
          solution: { type: 'array', items: { type: 'string' } },
          topics: { type: 'array', items: { type: 'string' } },
          difficulty: { type: 'integer' },
          confidence: { type: 'number' },
        },
      },
    },
    unreadable: {
      type: 'array',
      items: { type: 'object', required: ['page', 'reason'], properties: { page: { type: 'integer' }, reason: { type: 'string' } } },
    },
  },
});

/** Below this confidence a draft question is flagged `needsReview` for the admin. */
export const REVIEW_CONFIDENCE = 0.7;

/**
 * Validates and normalises one model response against `MODEL_OUTPUT_SCHEMA` + `LIMITS`. Throws
 * `ConversionSchemaError` for a response that cannot become a draft (the job is retried / failed); trims and clamps
 * what can be repaired safely. Returns `{ questions, unreadable }` where each question is the draft shape minus the
 * figure storage paths (cropping happens after this, from `figureBoxes`).
 */
export function validateModelOutput(output, { pageCount }) {
  if (!output || typeof output !== 'object' || !Array.isArray(output.questions)) {
    throw new ConversionSchemaError('bad-output', 'The model response has no questions array');
  }
  if (!Number.isInteger(pageCount) || pageCount < 1) {
    throw new ConversionSchemaError('bad-output', 'pageCount must be a positive integer');
  }
  if (output.questions.length === 0) throw new ConversionSchemaError('empty-output', 'The model found no questions');
  if (output.questions.length > LIMITS.questionsPerExam) {
    throw new ConversionSchemaError('too-many-questions', `More than ${LIMITS.questionsPerExam} questions`);
  }

  const seenLabels = new Set();
  const questions = output.questions.map((raw, index) => {
    const where = `question ${index + 1}`;
    const label = requiredText(raw?.label, LIMITS.label, `${where} label`);
    if (seenLabels.has(label)) throw new ConversionSchemaError('duplicate-label', `${where}: duplicate label ${label}`);
    seenLabels.add(label);
    const text = requiredText(raw.text, LIMITS.text, `${where} text`);
    const choices = list(raw.choices, LIMITS.choices, `${where} choices`).map((choice, k) => ({
      label: requiredText(choice?.label, LIMITS.choiceLabel, `${where} choice ${k + 1} label`),
      text: requiredText(choice?.text, LIMITS.choiceText, `${where} choice ${k + 1} text`),
    }));
    const figureBoxes = list(raw.figures, LIMITS.figuresPerQuestion, `${where} figures`).map((figure, k) =>
      figureBox(figure, pageCount, `${where} figure ${k + 1}`));
    const answerChoice = optionalText(raw.answer?.choice, LIMITS.choiceLabel);
    if (answerChoice && !choices.some((choice) => choice.label === answerChoice)) {
      throw new ConversionSchemaError('bad-answer', `${where}: answer choice ${answerChoice} is not one of the choices`);
    }
    return {
      order: index + 1,
      label,
      text,
      speech: optionalText(raw.speech, LIMITS.speech) ?? plainSpeech(text),
      choices,
      figureBoxes,
      hasFigure: figureBoxes.length > 0,
      answer: {
        text: requiredText(raw.answer?.text, LIMITS.answerText, `${where} answer`),
        ...(answerChoice ? { choice: answerChoice } : {}),
        ...(optionalText(raw.answer?.speech, LIMITS.speech) ? { speech: optionalText(raw.answer.speech, LIMITS.speech) } : {}),
      },
      // Over-long solutions / topic lists are cut, not rejected: they never make the draft unusable.
      solution: lenient(raw.solution)
        .map((step) => optionalText(step, LIMITS.solutionStep))
        .filter(Boolean)
        .slice(0, LIMITS.solutionSteps),
      topics: [...new Set(lenient(raw.topics)
        .map((topic) => slug(String(topic ?? '')).slice(0, LIMITS.topic))
        .filter((topic) => topic !== 'unknown'))].slice(0, LIMITS.topics),
      difficulty: clampInt(raw.difficulty, 1, 3, 2),
      confidence: clampNumber(raw.confidence, 0, 1, 0),
      needsReview: clampNumber(raw.confidence, 0, 1, 0) < REVIEW_CONFIDENCE,
    };
  });

  const unreadable = list(output.unreadable ?? [], LIMITS.unreadablePages, 'unreadable')
    .filter((entry) => Number.isInteger(entry?.page) && entry.page >= 1 && entry.page <= pageCount)
    .map((entry) => ({ page: entry.page, reason: optionalText(entry.reason, LIMITS.unreadableReason) ?? '' }));

  return { questions, unreadable };
}

// MARK: - Errors and helpers

export class ConversionSchemaError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'ConversionSchemaError';
    this.code = code;
  }
}

function requiredText(value, limit, where) {
  const text = optionalText(value, limit);
  if (!text) throw new ConversionSchemaError('missing-field', `${where} is empty`);
  return text;
}

/** Trimmed text cut to `limit` characters, or `undefined` when not a non-empty string. */
function optionalText(value, limit) {
  if (typeof value !== 'string') return undefined;
  const trimmed = value.trim();
  if (trimmed === '') return undefined;
  return [...trimmed].slice(0, limit).join('');
}

function list(value, limit, where) {
  if (value === undefined || value === null) return [];
  if (!Array.isArray(value)) throw new ConversionSchemaError('bad-output', `${where} is not an array`);
  if (value.length > limit) throw new ConversionSchemaError('bad-output', `${where} has more than ${limit} entries`);
  return value;
}

/** An array as-is, anything else as empty. */
function lenient(value) {
  return Array.isArray(value) ? value : [];
}

function figureBox(figure, pageCount, where) {
  const page = figure?.page;
  const box = figure?.box;
  if (!Number.isInteger(page) || page < 1 || page > pageCount) {
    throw new ConversionSchemaError('bad-figure', `${where}: page ${page} is outside 1…${pageCount}`);
  }
  if (!Array.isArray(box) || box.length !== 4 || !box.every((value) => Number.isFinite(value))) {
    throw new ConversionSchemaError('bad-figure', `${where}: box must be four numbers`);
  }
  const [x0, y0, x1, y1] = box.map((value) => Math.min(1000, Math.max(0, value)));
  if (x1 - x0 < 5 || y1 - y0 < 5) throw new ConversionSchemaError('bad-figure', `${where}: box is empty`);
  return { page, box: [x0, y0, x1, y1] };
}

function clampInt(value, min, max, fallback) {
  return Number.isInteger(value) ? Math.min(max, Math.max(min, value)) : fallback;
}

function clampNumber(value, min, max, fallback) {
  return Number.isFinite(value) ? Math.min(max, Math.max(min, value)) : fallback;
}

/** A last-resort VoiceOver text: the LaTeX delimiters and commands stripped (the model's `speech` is preferred). */
export function plainSpeech(text) {
  return text
    .replace(/\$\$?/g, '')
    .replace(/\\[a-zA-Z]+/g, ' ')
    .replace(/\\./g, ' ')
    .replace(/[{}^_]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

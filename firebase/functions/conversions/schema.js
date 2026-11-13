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
// - `questionPools/{poolId}`                question-id pools for the future practice mode (server writes).
// - `subjects/{subjectId}`                  country-wide course identities `{ name, aliases[] }` (server writes).
// - `aiUsage/{YYYY-MM}`                     monthly AI spend for the $50 cap (server only).
// Storage: `questionFigures/{jobId}/{nnn}-{k}.jpg` (server writes, +90 users and admins get one file at a time).
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
 * Canonical exam types — the ids of the app's `ExamNameCatalog` (Add Exam's fixed exam-name list). A title that
 * matches none of them parses to `examType: null` (it stays viewable, it just joins no typed pool).
 */
export const EXAM_TYPES = Object.freeze(['vize', 'final', 'butunleme', 'mazeret', 'kisa-sinav', 'yaz-okulu', 'ara-sinav']);

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
 * - publishExamConversion      { jobId, subjectId?, newSubjectName? }        → { examId, questionCount }  (2nd approval)
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

/** A cropped figure: `questionFigures/<jobId>/<nnn>-<k>.jpg`, `k` 1-based within the question. */
export function figureStoragePath(jobId, order, index) {
  if (!JOB_ID_PATTERN.test(jobId ?? '')) throw new ConversionSchemaError('invalid-job-id', 'Bad job id');
  if (!Number.isInteger(index) || index < 1 || index > LIMITS.figuresPerQuestion) {
    throw new ConversionSchemaError('invalid-figure-index', `Figure index must be 1…${LIMITS.figuresPerQuestion}`);
  }
  return `questionFigures/${jobId}/${questionOrderKey(order)}-${index}.jpg`;
}

/**
 * `questionPools/<subjectId>__<examType>__<scope>`, scope `tr` | `u-<universityId>` | `c-<courseId>`. A pool past
 * ~15k ids is continued in a `__p2` (… `__pN`) document; `part` 1 has no suffix.
 */
export function questionPoolId({ subjectId, examType, scope, universityId, courseId, part = 1 }) {
  if (!ID_SEGMENT_PATTERN.test(subjectId ?? '')) throw new ConversionSchemaError('invalid-pool', 'Bad subject id');
  if (!EXAM_TYPES.includes(examType)) throw new ConversionSchemaError('invalid-pool', 'Bad exam type');
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

// Checked in this order; the first hit wins (so "2019 YAZ OKULU FİNAL" is a final, "MAZERET VİZE" a make-up).
const TYPE_KEYS = Object.freeze([
  ['butunleme', ['butunleme']],
  ['mazeret', ['mazeret']],
  ['kisa-sinav', ['kisa-sinav', 'kisa-sinavlari', 'quiz']],
  ['ara-sinav', ['ara-sinav', 'arasinav']],
  ['vize', ['vize']],
  ['final', ['final']],
  ['yaz-okulu', ['yaz-okulu']],
]);

/**
 * Splits an archive exam title ("2019 FİNAL", "2017-2018 VİZE", "KISA SINAV 3") into `{ examType, year }`. The
 * year is the first 19xx/20xx number (an academic-year range keeps its first year); either part is `null` when
 * absent. Mirrors `ExamTitleParser.parse` in the app.
 */
export function parseExamTitle(title) {
  const key = slug(String(title ?? ''));
  const tokens = key.split('-');
  const yearToken = tokens.find((token) => /^(19|20)\d{2}$/.test(token));
  const padded = `-${key}-`;
  const match = TYPE_KEYS.find(([, needles]) => needles.some((needle) => padded.includes(`-${needle}-`)));
  return { examType: match ? match[0] : null, year: yearToken ? Number(yearToken) : null };
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

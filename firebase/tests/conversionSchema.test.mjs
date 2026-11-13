// The structured-exam contract (`functions/conversions/schema.js`): ids, the exam-title parser (parity with the
// app's ExamTitleParserTests), pool ids and AI output validation. Pure — no emulator needed.

import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import {
  ConversionSchemaError,
  EXAM_TYPES,
  PROVIDERS,
  conversionJobId,
  figureStoragePath,
  parseExamTitle,
  plainSpeech,
  publishedQuestionId,
  questionPoolId,
  usageMonthKey,
  validateModelOutput,
} from '../functions/conversions/schema.js';
import { slug as functionsSlug } from '../functions/conversions/slug.js';
import { slug as scriptsSlug } from '../scripts/slug.mjs';
import { TRIGGERS, conversionNotificationIds } from '../functions/notifications/automatic.js';
import { NOTIFICATION_ID_PATTERN } from '../functions/notifications/schema.js';
import { PROMPT_VERSION, SYSTEM_PROMPT } from '../functions/conversions/prompt.js';

const fails = (fn, code) => assert.throws(fn, (error) => error instanceof ConversionSchemaError && error.code === code);

describe('conversion schema — ids and paths', () => {
  test('job ids are exam-/sub- prefixed and reject bad sources', () => {
    assert.equal(conversionJobId({ type: 'legacy', examId: 'uni__fac__dep__ders__2019-final' }), 'exam-uni__fac__dep__ders__2019-final');
    assert.equal(conversionJobId({ type: 'submission', submissionId: 'abc123' }), 'sub-abc123');
    fails(() => conversionJobId({ type: 'legacy' }), 'invalid-source');
    fails(() => conversionJobId({ type: 'submission', submissionId: 'a/b' }), 'invalid-source');
    fails(() => conversionJobId({ type: 'other', examId: 'x' }), 'invalid-source');
  });

  test('published question ids and figure paths are zero-padded and stable', () => {
    assert.equal(publishedQuestionId('e1', 1), 'e1-001');
    assert.equal(publishedQuestionId('e1', 42), 'e1-042');
    assert.equal(figureStoragePath('exam-e1', 3, 2), 'questionFigures/exam-e1/003-2.jpg');
    assert.equal(figureStoragePath('exam-e1', 3, 2, 1), 'questionFigures/exam-e1/003-2.jpg');
    assert.equal(figureStoragePath('exam-e1', 3, 2, 4), 'questionFigures/exam-e1/003-2-r4.jpg');
    fails(() => figureStoragePath('exam-e1', 3, 2, 0), 'invalid-figure-revision');
    fails(() => figureStoragePath('exam-e1', 3, 2, 1.5), 'invalid-figure-revision');
    fails(() => publishedQuestionId('e1', 0), 'invalid-order');
    fails(() => publishedQuestionId('e1', 1000), 'invalid-order');
    fails(() => figureStoragePath('e1', 1, 1), 'invalid-job-id');
    fails(() => figureStoragePath('exam-e1', 1, 7), 'invalid-figure-index');
  });

  test('pool ids cover the three scopes and the part suffix', () => {
    assert.equal(questionPoolId({ subjectId: 'matematik-1', examType: 'final', scope: 'tr' }), 'matematik-1__final__tr');
    assert.equal(questionPoolId({ subjectId: 's', examType: 'vize', scope: 'university', universityId: 'bozok' }), 's__vize__u-bozok');
    assert.equal(questionPoolId({ subjectId: 's', examType: 'vize', scope: 'course', courseId: 'c1', part: 2 }), 's__vize__c-c1__p2');
    fails(() => questionPoolId({ subjectId: 's', examType: 'quiz', scope: 'tr' }), 'invalid-pool');
    fails(() => questionPoolId({ subjectId: 's', examType: 'vize', scope: 'university' }), 'invalid-pool');
  });

  test('the usage month is the Istanbul calendar month', () => {
    assert.equal(usageMonthKey(new Date('2026-11-30T20:59:59Z')), '2026-11');
    assert.equal(usageMonthKey(new Date('2026-11-30T21:00:00Z')), '2026-12');
  });

  test('providers and exam types are the agreed sets', () => {
    assert.deepEqual([...PROVIDERS], ['claude', 'gemini']);
    assert.deepEqual([...EXAM_TYPES], ['vize', 'final', 'butunleme', 'mazeret', 'kisa-sinav', 'yaz-okulu', 'ara-sinav']);
  });
});

describe('conversion schema — exam title parser (same cases as ExamTitleParserTests.swift)', () => {
  const cases = [
    ['2019 FİNAL', 'final', 2019],
    ['2018 VİZE', 'vize', 2018],
    ['2017-2018 VİZE', 'vize', 2017],
    ['2020 BÜTÜNLEME', 'butunleme', 2020],
    ['2021 MAZERET', 'mazeret', 2021],
    ['2019 KISA SINAV 2', 'kisa-sinav', 2019],
    ['KISA SINAV 3', 'kisa-sinav', null],
    ['2019 ARASINAV', 'ara-sinav', 2019],
    ['2022 ARA SINAV', 'ara-sinav', 2022],
    ['2019 YAZ OKULU FİNAL', 'final', 2019],
    ['2019 VİZE YAZ OKULU', 'vize', 2019],
    ['2023 YAZ OKULU', 'yaz-okulu', 2023],
    ['FİNAL', 'final', null],
    ['DERS NOTU', null, null],
    ['2019 TEK DERS', null, 2019],
    ['', null, null],
  ];
  for (const [title, examType, year] of cases) {
    test(`"${title}" -> ${examType} / ${year}`, () => {
      assert.deepEqual(parseExamTitle(title), { examType, year });
    });
  }
});

describe('conversion schema — model output validation', () => {
  const question = (overrides = {}) => ({
    label: '1',
    text: '$\\int_0^1 x\\,dx$ integralini hesaplayınız.',
    speech: 'sıfırdan bire x dx integralini hesaplayınız.',
    choices: [],
    figures: [],
    answer: { text: '$\\frac{1}{2}$' },
    solution: ['Ters türev $x^2/2$.', 'Sınırlar yerine konur.'],
    topics: ['Belirli İntegral'],
    difficulty: 1,
    confidence: 0.95,
    ...overrides,
  });

  test('a valid response is normalised into drafts', () => {
    const result = validateModelOutput({ questions: [question(), question({ label: '2', confidence: 0.4 })], unreadable: [] }, { pageCount: 2 });
    assert.equal(result.questions.length, 2);
    assert.equal(result.questions[0].order, 1);
    assert.deepEqual(result.questions[0].topics, ['belirli-integral']);
    assert.equal(result.questions[0].needsReview, false);
    assert.equal(result.questions[1].needsReview, true);
    assert.equal(result.questions[0].hasFigure, false);
  });

  test('multiple choice answers must name an existing choice', () => {
    const choices = [{ label: 'A', text: '1' }, { label: 'B', text: '2' }];
    const ok = validateModelOutput({ questions: [question({ choices, answer: { text: '2', choice: 'B' } })], unreadable: [] }, { pageCount: 1 });
    assert.equal(ok.questions[0].answer.choice, 'B');
    fails(() => validateModelOutput({ questions: [question({ choices, answer: { text: '2', choice: 'E' } })], unreadable: [] }, { pageCount: 1 }), 'bad-answer');
  });

  test('figure boxes are clamped and must sit on an existing page', () => {
    const ok = validateModelOutput({ questions: [question({ figures: [{ page: 1, box: [-5, 10, 500, 1200] }] })], unreadable: [] }, { pageCount: 1 });
    assert.deepEqual(ok.questions[0].figureBoxes, [{ page: 1, box: [0, 10, 500, 1000] }]);
    assert.equal(ok.questions[0].hasFigure, true);
    fails(() => validateModelOutput({ questions: [question({ figures: [{ page: 3, box: [0, 0, 10, 10] }] })], unreadable: [] }, { pageCount: 2 }), 'bad-figure');
    fails(() => validateModelOutput({ questions: [question({ figures: [{ page: 1, box: [0, 0, 2, 2] }] })], unreadable: [] }, { pageCount: 1 }), 'bad-figure');
  });

  test('empty, duplicate-label and missing-text responses are rejected', () => {
    fails(() => validateModelOutput({ questions: [], unreadable: [] }, { pageCount: 1 }), 'empty-output');
    fails(() => validateModelOutput({}, { pageCount: 1 }), 'bad-output');
    fails(() => validateModelOutput({ questions: [question(), question()], unreadable: [] }, { pageCount: 1 }), 'duplicate-label');
    fails(() => validateModelOutput({ questions: [question({ text: '  ' })], unreadable: [] }, { pageCount: 1 }), 'missing-field');
    fails(() => validateModelOutput({ questions: [question({ answer: {} })], unreadable: [] }, { pageCount: 1 }), 'missing-field');
  });

  test('out-of-range scores are clamped, long lists are cut, a missing speech falls back to plain text', () => {
    const many = Array.from({ length: 40 }, (_, i) => `adım ${i}`);
    const result = validateModelOutput({
      questions: [question({ difficulty: 9, confidence: 3, solution: many, speech: undefined, topics: Array(20).fill('x').map((t, i) => `${t}${i}`) })],
      unreadable: [{ page: 1, reason: 'bulanık' }, { page: 9, reason: 'yok' }],
    }, { pageCount: 1 });
    const draft = result.questions[0];
    assert.equal(draft.difficulty, 3);
    assert.equal(draft.confidence, 1);
    assert.equal(draft.solution.length, 30);
    assert.equal(draft.topics.length, 8);
    assert.ok(!draft.speech.includes('$') && !draft.speech.includes('\\'));
    assert.deepEqual(result.unreadable, [{ page: 1, reason: 'bulanık' }]);
  });

  test('plainSpeech strips LaTeX', () => {
    assert.equal(plainSpeech('$x^2 + \\frac{1}{2}$'), 'x 2 + 1 2');
  });
});

describe('conversion schema — shared pieces', () => {
  test('the functions slug copy matches scripts/slug.mjs', () => {
    for (const input of ['Sakarya Üniversitesi', 'İşletme', 'Mühendislik-Mimarlık Fakültesi', '2019 YAZ OKULU FİNAL', '', '...']) {
      assert.equal(functionsSlug(input), scriptsSlug(input));
    }
  });

  test('conversion notification triggers and ids are valid notification ids', () => {
    assert.equal(TRIGGERS.conversionReady, 'conversionReady');
    assert.equal(TRIGGERS.conversionFailed, 'conversionFailed');
    const short = conversionNotificationIds('sub-abc', 2);
    assert.deepEqual(short, { ready: 'auto-convready-sub-abc', failed: 'auto-convfailed-sub-abc-2' });
    const long = conversionNotificationIds(`exam-${'x'.repeat(300)}`, 1);
    assert.match(long.ready, NOTIFICATION_ID_PATTERN);
    assert.match(long.failed, NOTIFICATION_ID_PATTERN);
    assert.equal(long.ready, conversionNotificationIds(`exam-${'x'.repeat(300)}`, 5).ready);
  });

  test('the prompt is versioned and mentions every schema field', () => {
    assert.equal(PROMPT_VERSION, 1);
    for (const field of ['label', 'text', 'speech', 'choices', 'figures', 'answer', 'solution', 'topics', 'difficulty', 'confidence', 'unreadable']) {
      assert.ok(SYSTEM_PROMPT.includes(`"${field}"`), field);
    }
  });
});

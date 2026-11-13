// The AI conversion pipeline (`functions/conversions/pipeline.js`, Faz 1A) against the Firestore and Storage
// emulators, with a fake model provider (nothing reaches Vertex AI), plus the pure parts (costs, the cap, provider
// request/response mapping, figure geometry, PDF page counting) without the emulator.
//
// Covered: happy path (drafts + figures + usage + ready + notice), the recorded provider, the monthly cap (queued +
// one notice + re-enqueue; one-time budget exempt), invalid model output (retry, then failed on the last attempt),
// permanent errors, idempotency of re-delivered tasks, the lease, stale drafts/figures, PDFs with and without a
// rasteriser, a job discarded mid-run (drafts untouched), and single-question regeneration (draft / published
// target, skips, the cap, retries, the lease).

import { test, before, after, beforeEach, describe, mock } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { PROJECT_ID, assertLocalEmulators } from './helpers.mjs';

const requireFromFunctions = createRequire(new URL('../functions/package.json', import.meta.url));
const { initializeApp, deleteApp } = requireFromFunctions('firebase-admin/app');
const { getFirestore } = requireFromFunctions('firebase-admin/firestore');
const { getStorage } = requireFromFunctions('firebase-admin/storage');
const sharp = requireFromFunctions('sharp');

const BUCKET = `${PROJECT_ID}.appspot.com`;
const NOW = new Date('2026-11-13T09:00:00Z'); // 12:00 in Türkiye
const MONTH = '2026-11';

const usage = await import('../functions/conversions/usage.js');
const images = await import('../functions/conversions/images.js');
const common = await import('../functions/conversions/providers/common.js');
const claude = await import('../functions/conversions/providers/claude.js');
const gemini = await import('../functions/conversions/providers/gemini.js');
const providers = await import('../functions/conversions/providers/index.js');
const { MODEL_OUTPUT_SCHEMA } = await import('../functions/conversions/schema.js');
const { SYSTEM_PROMPT } = await import('../functions/conversions/prompt.js');

// --- Pure parts ---------------------------------------------------------------------------------------------------

describe('usage — costs and the monthly cap', () => {
  test('cost follows the configured per-token prices, Gemini tiered by prompt size', () => {
    const { claude: c, gemini: g } = providers.PROVIDER_CONFIG;
    const [cTier] = c.pricing.tiers;
    assert.equal(usage.costUsd('claude', { inputTokens: 1_000_000, outputTokens: 0 }), cTier.inputPerMTok);
    assert.equal(usage.costUsd('claude', { inputTokens: 0, outputTokens: 1_000_000 }), cTier.outputPerMTok);
    const [small, large] = g.pricing.tiers;
    assert.equal(usage.costUsd('gemini', { inputTokens: 100_000, outputTokens: 0 }), small.inputPerMTok / 10);
    assert.equal(usage.costUsd('gemini', { inputTokens: 300_000, outputTokens: 0 }), (large.inputPerMTok * 3) / 10);
    assert.equal(usage.costUsd('gemini', {}), 0);
    assert.throws(() => usage.costUsd('gpt', {}), /Unknown provider/);
  });

  test('estimates scale with pages and the cap counts spend plus the estimate', () => {
    const one = usage.estimateJobCostUsd({ provider: 'claude', pageCount: 1 });
    assert.ok(one > 0);
    assert.ok(Math.abs(usage.estimateJobCostUsd({ provider: 'claude', pageCount: 5 }) - one * 5) < 1e-9);
    assert.equal(usage.estimateJobCostUsd({ provider: 'gemini', pageCount: 0 }), usage.estimateJobCostUsd({ provider: 'gemini', pageCount: 1 }));
    assert.equal(usage.MONTHLY_CAP_USD, 50);
    assert.equal(usage.isOverCap({ spentUsd: 49, estimateUsd: 0.5 }), false);
    assert.equal(usage.isOverCap({ spentUsd: 49.8, estimateUsd: 0.5 }), true);
    assert.equal(usage.isOverCap({ spentUsd: 0, estimateUsd: 2, capUsd: 1 }), true);
  });

  test('only an explicit oneTime budget escapes the cap', () => {
    assert.equal(usage.jobBudget({ budget: 'oneTime' }), 'oneTime');
    assert.equal(usage.jobBudget({}), 'monthly');
    assert.equal(usage.jobBudget({ budget: 'other' }), 'monthly');
  });

  test('next month starts at 00:00 Istanbul time', () => {
    assert.equal(usage.nextMonthStart(NOW).toISOString(), '2026-11-30T21:00:00.000Z');
    // 23:30 on 31 Dec in Istanbul is already the last evening of the year there.
    assert.equal(usage.nextMonthStart(new Date('2026-12-31T20:30:00Z')).toISOString(), '2026-12-31T21:00:00.000Z');
    assert.equal(usage.nextMonthStart(new Date('2026-12-31T21:30:00Z')).toISOString(), '2027-01-31T21:00:00.000Z');
  });
});

describe('providers — request and response mapping', () => {
  const files = [
    { bytes: Buffer.from('%PDF-1.4'), mimeType: 'application/pdf' },
    { bytes: Buffer.from([0xff, 0xd8, 0xff]), mimeType: 'image/jpeg' },
  ];

  test('closedSchema closes every object without touching the shared schema', () => {
    const closed = common.closedSchema(MODEL_OUTPUT_SCHEMA);
    assert.equal(closed.additionalProperties, false);
    assert.equal(closed.properties.questions.items.additionalProperties, false);
    assert.equal(closed.properties.questions.items.properties.answer.additionalProperties, false);
    assert.equal(MODEL_OUTPUT_SCHEMA.additionalProperties, undefined);
  });

  test('Claude: system prompt, document + image blocks, structured output and effort', () => {
    const request = claude.buildClaudeRequest({ files, kind: 'PDF', pageCount: 3 });
    assert.equal(request.model, providers.PROVIDER_CONFIG.claude.modelId);
    assert.equal(request.system, SYSTEM_PROMPT);
    const [doc, image, text] = request.messages[0].content;
    assert.deepEqual(doc.source, { type: 'base64', media_type: 'application/pdf', data: files[0].bytes.toString('base64') });
    assert.equal(image.type, 'image');
    assert.equal(image.source.media_type, 'image/jpeg');
    assert.match(text.text, /3 page/);
    assert.equal(request.output_config.format.type, 'json_schema');
    assert.equal(request.output_config.format.schema.additionalProperties, false);
    assert.equal(request.output_config.effort, providers.PROVIDER_CONFIG.claude.effort);
    assert.equal(request.thinking, undefined, 'Opus 5.5 thinking is adaptive by default');
  });

  test('Claude: final message → output + usage; refusal / max_tokens / bad JSON keep the billed usage', () => {
    const message = (overrides) => ({
      stop_reason: 'end_turn',
      content: [{ type: 'thinking', thinking: '' }, { type: 'text', text: '{"questions":[],' }, { type: 'text', text: '"unreadable":[]}' }],
      usage: { input_tokens: 100, output_tokens: 50, cache_read_input_tokens: 10 },
      ...overrides,
    });
    assert.deepEqual(claude.readClaudeMessage(message()), {
      output: { questions: [], unreadable: [] }, usage: { inputTokens: 110, outputTokens: 50 },
    });
    for (const [overrides, code] of [
      [{ stop_reason: 'refusal', stop_details: { category: 'cyber' } }, 'refusal'],
      [{ stop_reason: 'max_tokens' }, 'max-tokens'],
      [{ content: [{ type: 'text', text: 'not json' }] }, 'invalid-json'],
      [{ content: [] }, 'empty-response'],
    ]) {
      assert.throws(() => claude.readClaudeMessage(message(overrides)), (error) =>
        error instanceof common.ProviderError && error.code === code && error.retryable && error.usage.outputTokens === 50);
    }
  });

  test('Claude provider streams through an injected client; 4xx is permanent, 429/5xx retryable', async () => {
    const calls = [];
    const fakeClient = (result) => ({
      messages: {
        stream(body) {
          calls.push(body);
          return { finalMessage: async () => { if (result instanceof Error) throw result; return result; } };
        },
      },
    });
    const ok = providers.createProvider('claude', {
      client: fakeClient({ stop_reason: 'end_turn', content: [{ type: 'text', text: '{"questions":[]}' }], usage: { input_tokens: 1, output_tokens: 2 } }),
    });
    assert.equal(ok.name, 'claude');
    const result = await ok.solveExam({ files, kind: 'PDF', pageCount: 2 });
    assert.deepEqual(result, { output: { questions: [] }, usage: { inputTokens: 1, outputTokens: 2 } });
    assert.equal(calls.length, 1);

    const forbidden = providers.createProvider('claude', { client: fakeClient(Object.assign(new Error('not enabled'), { status: 403 })) });
    await assert.rejects(forbidden.solveExam({ files, kind: 'PDF', pageCount: 2 }), (error) => error.retryable === false);
    const limited = providers.createProvider('claude', { client: fakeClient(Object.assign(new Error('slow down'), { status: 429 })) });
    await assert.rejects(limited.solveExam({ files, kind: 'PDF', pageCount: 2 }), (error) => error.retryable === true);
  });

  test('Gemini: inline data, JSON schema, thinking level; thoughts count as output', async () => {
    const request = gemini.buildGeminiRequest({ files, kind: 'JPG', pageCount: 2 });
    assert.equal(request.model, providers.PROVIDER_CONFIG.gemini.modelId);
    assert.equal(request.config.systemInstruction, SYSTEM_PROMPT);
    assert.equal(request.config.responseMimeType, 'application/json');
    assert.equal(request.config.responseJsonSchema, MODEL_OUTPUT_SCHEMA);
    assert.deepEqual(request.contents[0].parts[0].inlineData, { mimeType: 'application/pdf', data: files[0].bytes.toString('base64') });
    assert.match(request.contents[0].parts[2].text, /2 page/);

    const response = (finishReason, text = '{"questions":[]}') => ({
      candidates: [{ finishReason, content: { parts: [{ text: 'thinking…', thought: true }, { text }] } }],
      usageMetadata: { promptTokenCount: 10, candidatesTokenCount: 5, thoughtsTokenCount: 7 },
    });
    assert.deepEqual(gemini.readGeminiResponse(response('STOP')), { output: { questions: [] }, usage: { inputTokens: 10, outputTokens: 12 } });
    assert.throws(() => gemini.readGeminiResponse(response('MAX_TOKENS')), (error) => error.code === 'max-tokens' && error.usage.outputTokens === 12);
    assert.throws(() => gemini.readGeminiResponse(response('SAFETY')), (error) => error.code === 'finish');
    assert.throws(() => gemini.readGeminiResponse({ promptFeedback: { blockReason: 'OTHER' } }), (error) => error.code === 'blocked');

    const sent = [];
    const provider = providers.createProvider('gemini', {
      client: { models: { generateContent: async (params) => { sent.push(params); return response('STOP'); } } },
    });
    assert.equal((await provider.solveExam({ files, kind: 'JPG', pageCount: 2 })).usage.inputTokens, 10);
    assert.equal(sent[0].config.thinkingConfig.thinkingLevel, providers.PROVIDER_CONFIG.gemini.thinkingLevel);
  });

  test('provider names come from the contract; no default', () => {
    assert.throws(() => providers.createProvider(undefined), /Unknown AI provider/);
    assert.throws(() => providers.createProvider('openai'), /Unknown AI provider/);
    const get = providers.liveProviders();
    assert.equal(get('gemini'), get('gemini'));
    assert.equal(get('claude').modelId, providers.PROVIDER_CONFIG.claude.modelId);
  });
});

describe('images — figure geometry and PDF pages', () => {
  test('pixelRect pads, clamps and rejects empty boxes', () => {
    assert.deepEqual(images.pixelRect([100, 200, 500, 600], 1000, 2000, 0), { left: 100, top: 400, width: 400, height: 800 });
    assert.deepEqual(images.pixelRect([0, 0, 1000, 1000], 300, 400), { left: 0, top: 0, width: 300, height: 400 });
    assert.equal(images.pixelRect([500, 500, 500, 500], 100, 100, 0), null);
  });

  test('pdfPageCount reads the page tree, else counts page objects, else null', () => {
    assert.equal(images.pdfPageCount(Buffer.from(fakePdf(3))), 3);
    const noTree = '%PDF-1.4\n1 0 obj << /Type /Page >> endobj\n2 0 obj << /Type /Page >> endobj\n';
    assert.equal(images.pdfPageCount(Buffer.from(noTree)), 2);
    assert.equal(images.pdfPageCount(Buffer.from('%PDF-1.7\n1 0 obj << /Type /ObjStm /N 9 >> stream … endstream endobj')), null);
  });
});

// --- Pipeline against the emulators -------------------------------------------------------------------------------

let db;
let bucket;
let pipeline;
let TRIGGERS;

before(async () => {
  assertLocalEmulators('FIRESTORE_EMULATOR_HOST', 'FIREBASE_STORAGE_EMULATOR_HOST');
  mock.method(console, 'error', () => {});
  mock.method(console, 'warn', () => {});
  initializeApp({ projectId: PROJECT_ID, storageBucket: BUCKET });
  db = getFirestore('vifi');
  bucket = getStorage().bucket(BUCKET);
  pipeline = await import('../functions/conversions/pipeline.js');
  ({ TRIGGERS } = await import('../functions/notifications/automatic.js'));
});

after(async () => {
  const { getApp } = requireFromFunctions('firebase-admin/app');
  await deleteApp(getApp());
});

async function clearFirestore() {
  const host = process.env.FIRESTORE_EMULATOR_HOST;
  const response = await fetch(`http://${host}/emulator/v1/projects/${PROJECT_ID}/databases/vifi/documents`, { method: 'DELETE' });
  assert.ok(response.ok, `clearing the Firestore emulator failed: ${response.status}`);
}

beforeEach(async () => {
  await clearFirestore();
  await bucket.deleteFiles({ prefix: 'questionFigures/' });
  await bucket.deleteFiles({ prefix: 'imagess/' });
  await bucket.deleteFiles({ prefix: 'pdfs/' });
});

// --- Fixtures -----------------------------------------------------------------------------------------------------

/** A minimal, uncompressed PDF skeleton with a page tree of `pages` pages (enough for page counting). */
function fakePdf(pages) {
  const kids = Array.from({ length: pages }, (_, k) => `${k + 3} 0 R`).join(' ');
  const pageObjects = Array.from({ length: pages }, (_, k) => `${k + 3} 0 obj << /Type /Page /Parent 2 0 R >> endobj\n`).join('');
  return `%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n2 0 obj << /Type /Pages /Kids [${kids}] /Count ${pages} >> endobj\n${pageObjects}%%EOF\n`;
}

/** A white "scanned page" (portrait) with a black block where the figure is. */
async function pageImage({ width = 1000, height = 1400 } = {}) {
  const block = await sharp({ create: { width: 200, height: 200, channels: 3, background: '#000000' } }).png().toBuffer();
  return sharp({ create: { width, height, channels: 3, background: '#ffffff' } })
    .composite([{ input: block, left: 400, top: 600 }])
    .jpeg()
    .toBuffer();
}

async function upload(storagePath, bytes, contentType) {
  await bucket.file(storagePath).save(bytes, { contentType, resumable: false });
  return storagePath;
}

async function seedJob(jobId, overrides = {}) {
  const files = overrides.files ?? [
    { storagePath: await upload(`imagess/${jobId}-1.jpg`, await pageImage(), 'image/jpeg'), order: 0 },
    { storagePath: await upload(`imagess/${jobId}-2.jpg`, await pageImage({ width: 3000, height: 4000 }), 'image/jpeg'), order: 1 },
  ];
  const { files: _ignored, ...rest } = overrides;
  const data = {
    source: { type: 'legacy', examId: jobId.replace(/^exam-/, '') },
    kind: 'JPG',
    status: 'queued',
    attempts: 0,
    model: { provider: 'gemini' },
    files,
    createdAt: NOW,
    ...rest,
  };
  // `undefined` in an override removes the field.
  for (const key of Object.keys(data)) if (data[key] === undefined) delete data[key];
  await db.collection('examConversions').doc(jobId).set(data);
  return files;
}

const question = (label, overrides = {}) => ({
  label,
  text: `Soru ${label}: $\\int_0^1 x\\,dx$ değerini bulunuz.`,
  speech: `Soru ${label}: sıfırdan bire x d x integrali.`,
  choices: [],
  figures: [],
  answer: { text: '$\\frac{1}{2}$', speech: 'bir bölü iki' },
  solution: ['$\\int_0^1 x\\,dx = \\frac{x^2}{2}\\Big|_0^1$', '$= \\frac{1}{2}$'],
  topics: ['Belirli İntegral'],
  difficulty: 1,
  confidence: 0.92,
  ...overrides,
});

const GOOD_OUTPUT = {
  questions: [
    question('1'),
    question('2', {
      figures: [{ page: 2, box: [400, 428, 600, 571] }],
      choices: [{ label: 'A', text: '1' }, { label: 'B', text: '2' }],
      answer: { text: '2', choice: 'B' },
      confidence: 0.4,
    }),
  ],
  unreadable: [{ page: 1, reason: 'Alt kısım bulanık' }],
};

/** A fake provider: records its inputs, answers with `outputs` in turn (an Error is thrown). */
function fakeProvider(name, outputs, { usagePerRun = { inputTokens: 6000, outputTokens: 4000 }, onSolve } = {}) {
  const provider = {
    name,
    modelId: `fake-${name}-model`,
    calls: [],
    async solveExam(input) {
      provider.calls.push(input);
      await onSolve?.(input);
      const next = outputs[Math.min(provider.calls.length - 1, outputs.length - 1)];
      if (next instanceof Error) throw next;
      return { output: structuredClone(next), usage: usagePerRun };
    },
  };
  return provider;
}

function makeDeps({ outputs = [GOOD_OUTPUT], provider, ...overrides } = {}) {
  const fakes = {
    claude: provider?.name === 'claude' ? provider : fakeProvider('claude', outputs),
    gemini: provider?.name === 'gemini' ? provider : fakeProvider('gemini', outputs),
  };
  const notices = [];
  const enqueued = [];
  const requested = [];
  return {
    deps: {
      db,
      bucket,
      now: () => NOW,
      getProvider: (name) => { requested.push(name); return fakes[name]; },
      notifyAdmins: async (notice) => { notices.push(notice); },
      enqueue: async (data, options) => { enqueued.push({ data, options }); },
      ...overrides,
    },
    fakes,
    notices,
    enqueued,
    requested,
  };
}

const jobDoc = async (jobId) => (await db.collection('examConversions').doc(jobId).get()).data();
const draftDocs = async (jobId) => {
  const snapshot = await db.collection('examConversions').doc(jobId).collection('questions').orderBy('order').get();
  return snapshot.docs.map((doc) => ({ id: doc.id, ...doc.data() }));
};
const usageDoc = async (month = MONTH) => (await db.collection('aiUsage').doc(month).get()).data();
const figureNames = async (jobId) => (await bucket.getFiles({ prefix: `questionFigures/${jobId}/` }))[0].map((file) => file.name).sort();

describe('processExamConversion — happy path', () => {
  test('writes drafts, crops figures, records usage and the provider, marks ready and notifies', async () => {
    const jobId = 'exam-uni__fak__bol__ders__2019-final';
    await seedJob(jobId);
    const { deps, fakes, notices, requested } = makeDeps();

    const result = await pipeline.processExamConversionHandler(deps, { jobId, retryCount: 0 });
    assert.equal(result.outcome, 'ready');
    assert.equal(result.questionCount, 2);
    assert.deepEqual(requested.filter((name) => name !== 'gemini'), [], 'only the job\'s provider is used');

    // The model saw two normalised JPEG pages.
    const [call] = fakes.gemini.calls;
    assert.equal(call.pageCount, 2);
    assert.equal(call.kind, 'JPG');
    assert.deepEqual(call.files.map((file) => file.mimeType), ['image/jpeg', 'image/jpeg']);
    const secondPage = await sharp(call.files[1].bytes).metadata();
    assert.equal(Math.max(secondPage.width, secondPage.height), images.MODEL_IMAGE_MAX);

    const job = await jobDoc(jobId);
    assert.equal(job.status, 'ready');
    assert.equal(job.readyAt.toDate().toISOString(), NOW.toISOString());
    assert.equal(job.attempts, 1);
    assert.deepEqual(job.model, { provider: 'gemini', id: 'fake-gemini-model' });
    assert.equal(job.promptVersion, 1);
    assert.equal(job.questionCount, 2);
    assert.equal(job.needsReviewCount, 1);
    assert.equal(job.pageCount, 2);
    assert.deepEqual(job.unreadable, [{ page: 1, reason: 'Alt kısım bulanık' }]);
    assert.equal(job.leaseUntil, undefined);
    const expectedCost = usage.costUsd('gemini', { inputTokens: 6000, outputTokens: 4000 });
    assert.deepEqual(job.usage, { inputTokens: 6000, outputTokens: 4000, costUsd: expectedCost });

    const month = await usageDoc();
    assert.equal(month.costUsd, expectedCost);
    assert.equal(month.runs, 1);
    assert.equal(month.byProvider.gemini.costUsd, expectedCost);
    assert.equal(month.oneTime, undefined);

    const drafts = await draftDocs(jobId);
    assert.deepEqual(drafts.map((draft) => draft.id), ['001', '002']);
    const [first, second] = drafts;
    assert.equal(first.schemaVersion, 1);
    assert.equal(first.label, '1');
    assert.deepEqual(first.figures, []);
    assert.equal(first.hasFigure, false);
    assert.deepEqual(first.topics, ['belirli-integral']);
    assert.equal(first.needsReview, false);
    assert.equal(first.provider, 'gemini');
    assert.equal(second.needsReview, true, 'low confidence');
    assert.deepEqual(second.answer, { text: '2', choice: 'B' });
    assert.equal(second.hasFigure, true);
    assert.equal(second.pendingFigures, undefined);
    assert.equal(second.figures.length, 1);
    assert.equal(second.figures[0].storagePath, `questionFigures/${jobId}/002-1.jpg`);
    assert.ok(second.figures[0].width > 0 && second.figures[0].width <= images.FIGURE_MAX);
    assert.ok(second.figures[0].height > 0 && second.figures[0].height <= images.FIGURE_MAX);

    const [figure] = await bucket.file(second.figures[0].storagePath).download();
    const meta = await sharp(figure).metadata();
    assert.equal(meta.format, 'jpeg');
    assert.deepEqual([meta.width, meta.height], [second.figures[0].width, second.figures[0].height]);
    assert.deepEqual(await figureNames(jobId), [`questionFigures/${jobId}/002-1.jpg`]);

    assert.deepEqual(notices, [{ trigger: TRIGGERS.conversionReady, jobId, attempts: 1 }]);
  });

  test('a Claude job uses and records Claude', async () => {
    const jobId = 'sub-claude-1';
    await seedJob(jobId, { source: { type: 'submission', submissionId: 'claude-1' }, model: { provider: 'claude' } });
    const { deps, fakes, requested } = makeDeps();
    assert.equal((await pipeline.processExamConversionHandler(deps, { jobId })).outcome, 'ready');
    assert.equal(fakes.claude.calls.length, 1);
    assert.equal(fakes.gemini.calls.length, 0);
    assert.ok(requested.every((name) => name === 'claude'));
    const job = await jobDoc(jobId);
    assert.deepEqual(job.model, { provider: 'claude', id: 'fake-claude-model' });
    const month = await usageDoc();
    assert.equal(month.byProvider.claude.runs, 1);
    assert.equal(month.byProvider.gemini, undefined);
    assert.equal((await draftDocs(jobId))[0].provider, 'claude');
  });

  test('a re-delivered task for a ready job does nothing', async () => {
    const jobId = 'exam-redelivered';
    await seedJob(jobId);
    const { deps, fakes, notices } = makeDeps();
    await pipeline.processExamConversionHandler(deps, { jobId });
    const before = await jobDoc(jobId);
    const again = await pipeline.processExamConversionHandler(deps, { jobId });
    assert.deepEqual(again, { outcome: 'skipped', reason: 'status-ready' });
    assert.equal(fakes.gemini.calls.length, 1);
    assert.deepEqual(await jobDoc(jobId), before);
    assert.equal((await usageDoc()).runs, 1);
    assert.equal(notices.length, 1);
  });

  test('jobs that are missing, terminal or have no provider are skipped', async () => {
    const { deps, fakes } = makeDeps();
    assert.equal((await pipeline.processExamConversionHandler(deps, { jobId: 'exam-nope' })).reason, 'missing');
    assert.equal((await pipeline.processExamConversionHandler(deps, { jobId: 'bad id' })).reason, 'bad-job-id');
    await seedJob('exam-waiting', { model: undefined });
    assert.equal((await pipeline.processExamConversionHandler(deps, { jobId: 'exam-waiting' })).reason, 'no-provider');
    assert.equal((await jobDoc('exam-waiting')).status, 'queued');
    for (const status of ['published', 'discarded', 'failed']) {
      await seedJob(`exam-${status}`, { status });
      assert.equal((await pipeline.processExamConversionHandler(deps, { jobId: `exam-${status}` })).reason, `status-${status}`);
    }
    assert.equal(fakes.gemini.calls.length, 0);
  });
});

describe('processExamConversion — monthly cap', () => {
  test('over the cap the job stays queued, admins get one notice per month, and it is re-enqueued for next month', async () => {
    await db.collection('aiUsage').doc(MONTH).set({ month: MONTH, costUsd: 49.99 });
    await seedJob('exam-capped-1', { status: 'queued' });
    await seedJob('exam-capped-2', { status: 'processing', attempts: 1 });
    const { deps, fakes, notices, enqueued } = makeDeps();

    const first = await pipeline.processExamConversionHandler(deps, { jobId: 'exam-capped-1' });
    assert.equal(first.outcome, 'deferred');
    const second = await pipeline.processExamConversionHandler(deps, { jobId: 'exam-capped-2' });
    assert.equal(second.outcome, 'deferred');
    assert.equal(fakes.gemini.calls.length, 0);

    for (const jobId of ['exam-capped-1', 'exam-capped-2']) {
      const job = await jobDoc(jobId);
      assert.equal(job.status, 'queued');
      assert.equal(job.budgetDeferredMonth, MONTH);
      assert.equal(job.deferredUntil.toDate().toISOString(), '2026-11-30T21:00:00.000Z');
    }
    assert.equal(notices.length, 1);
    assert.equal(notices[0].trigger, pipeline.PIPELINE_NOTICES.budgetExceeded);
    assert.equal(notices[0].jobId, 'exam-capped-1');
    assert.equal(notices[0].month, MONTH);
    assert.equal(notices[0].capUsd, 50);
    assert.ok((await usageDoc()).capNotifiedAt);
    assert.deepEqual(enqueued.map((entry) => entry.data.jobId), ['exam-capped-1', 'exam-capped-2']);
    assert.equal(enqueued[0].options.scheduleTime.toISOString(), '2026-11-30T21:00:00.000Z');
    assert.equal((await usageDoc()).costUsd, 49.99, 'nothing was spent');

    // Next month the same job runs and clears its deferral.
    const december = new Date('2026-12-01T09:00:00Z');
    const later = makeDeps({ now: () => december });
    assert.equal((await pipeline.processExamConversionHandler(later.deps, { jobId: 'exam-capped-1' })).outcome, 'ready');
    const job = await jobDoc('exam-capped-1');
    assert.equal(job.budgetDeferredMonth, undefined);
    assert.equal(job.deferredUntil, undefined);
    assert.equal((await usageDoc('2026-12')).runs, 1);
  });

  test('one-time (script) jobs ignore the cap and are summed separately', async () => {
    await db.collection('aiUsage').doc(MONTH).set({ month: MONTH, costUsd: 60 });
    await seedJob('exam-script', { budget: 'oneTime' });
    const { deps, notices } = makeDeps();
    assert.equal((await pipeline.processExamConversionHandler(deps, { jobId: 'exam-script' })).outcome, 'ready');
    const month = await usageDoc();
    assert.equal(month.costUsd, 60, 'the capped total is untouched');
    assert.equal(month.oneTime.runs, 1);
    assert.equal(month.oneTime.costUsd, usage.costUsd('gemini', { inputTokens: 6000, outputTokens: 4000 }));
    assert.equal(month.byProvider.gemini.runs, 1);
    assert.deepEqual(notices.map((notice) => notice.trigger), [TRIGGERS.conversionReady]);
  });
});

describe('processExamConversion — failures and retries', () => {
  const BAD_OUTPUT = { questions: [{ label: '1', text: '' }], unreadable: [] };

  test('invalid model output is retried (usage still counted), then fails the job on the last attempt', async () => {
    const jobId = 'exam-invalid';
    await seedJob(jobId);
    const { deps, notices } = makeDeps({ outputs: [BAD_OUTPUT] });

    await assert.rejects(pipeline.processExamConversionHandler(deps, { jobId, retryCount: 0 }), (error) => error.code === 'missing-field');
    let job = await jobDoc(jobId);
    assert.equal(job.status, 'processing');
    assert.match(job.error, /missing-field/);
    assert.equal(job.leaseUntil, undefined, 'the lease is released for the retry');
    assert.equal(job.usage.inputTokens, 6000);
    assert.equal(notices.length, 0);

    await assert.rejects(pipeline.processExamConversionHandler(deps, { jobId, retryCount: 1 }));
    const result = await pipeline.processExamConversionHandler(deps, { jobId, retryCount: 2 });
    assert.equal(result.outcome, 'failed');
    job = await jobDoc(jobId);
    assert.equal(job.status, 'failed');
    assert.equal(job.attempts, 3);
    assert.match(job.error, /missing-field/);
    assert.equal(job.failedAt.toDate().toISOString(), NOW.toISOString());
    assert.equal(job.usage.inputTokens, 18000, 'every billed run is counted');
    assert.equal((await usageDoc()).runs, 3);
    assert.deepEqual(await draftDocs(jobId), []);
    assert.deepEqual(notices, [{ trigger: TRIGGERS.conversionFailed, jobId, attempts: 3 }]);
  });

  test('a provider error with billed usage counts it; a permanent provider error fails at once', async () => {
    const billed = new common.ProviderError('max-tokens', 'too long', { usage: { inputTokens: 10, outputTokens: 20 } });
    await seedJob('exam-billed');
    const first = makeDeps({ outputs: [billed] });
    await assert.rejects(pipeline.processExamConversionHandler(first.deps, { jobId: 'exam-billed' }));
    assert.equal((await jobDoc('exam-billed')).usage.outputTokens, 20);

    await seedJob('exam-forbidden');
    const forbidden = makeDeps({ outputs: [new common.ProviderError('request-failed', '403', { retryable: false })] });
    const result = await pipeline.processExamConversionHandler(forbidden.deps, { jobId: 'exam-forbidden', retryCount: 0 });
    assert.equal(result.outcome, 'failed');
    assert.equal((await jobDoc('exam-forbidden')).status, 'failed');
    assert.equal(forbidden.notices[0].trigger, TRIGGERS.conversionFailed);
  });

  test('a missing file fails the job on the first attempt', async () => {
    const jobId = 'exam-missing-file';
    await seedJob(jobId, { files: [{ storagePath: 'imagess/does-not-exist.jpg', order: 0 }] });
    const { deps, fakes, notices } = makeDeps();
    const result = await pipeline.processExamConversionHandler(deps, { jobId, retryCount: 0 });
    assert.equal(result.outcome, 'failed');
    assert.match((await jobDoc(jobId)).error, /^missing-file/);
    assert.equal(fakes.gemini.calls.length, 0);
    assert.equal(notices[0].trigger, TRIGGERS.conversionFailed);
  });

  test('a job leased by another delivery is retried later, or left alone on the last attempt', async () => {
    const jobId = 'exam-leased';
    await seedJob(jobId, { status: 'processing', attempts: 1, leaseUntil: new Date(NOW.getTime() + 60_000) });
    const { deps, fakes } = makeDeps();
    await assert.rejects(pipeline.processExamConversionHandler(deps, { jobId, retryCount: 0 }), (error) => error.code === 'lease-held');
    assert.deepEqual(await pipeline.processExamConversionHandler(deps, { jobId, retryCount: 2 }), { outcome: 'skipped', reason: 'leased' });
    assert.equal(fakes.gemini.calls.length, 0);
    assert.equal((await jobDoc(jobId)).status, 'processing');

    // An expired lease (the earlier run crashed) is taken over.
    await db.collection('examConversions').doc(jobId).update({ leaseUntil: new Date(NOW.getTime() - 1) });
    assert.equal((await pipeline.processExamConversionHandler(deps, { jobId, retryCount: 1 })).outcome, 'ready');
    assert.equal((await jobDoc(jobId)).attempts, 2);
  });

  test('a job discarded while the model runs is left discarded', async () => {
    const jobId = 'exam-discarded-midway';
    await seedJob(jobId);
    const provider = fakeProvider('gemini', [GOOD_OUTPUT], {
      onSolve: () => db.collection('examConversions').doc(jobId).update({ status: 'discarded' }),
    });
    await db.collection('examConversions').doc(jobId).collection('questions').doc('001').set({ order: 1, label: '1', text: 'eski' });
    const { deps, notices } = makeDeps({ provider });
    assert.equal((await pipeline.processExamConversionHandler(deps, { jobId })).outcome, 'abandoned');
    assert.equal((await jobDoc(jobId)).status, 'discarded');
    assert.deepEqual((await draftDocs(jobId)).map((draft) => draft.text), ['eski'], 'a discarded job keeps its drafts as they were');
    assert.deepEqual(await figureNames(jobId), [], 'and gets no new figures');
    assert.equal(notices.length, 0);
  });
});

describe('processExamConversion — regeneration and PDFs', () => {
  test('a re-run replaces the earlier drafts and removes their stale figures', async () => {
    const jobId = 'exam-rerun';
    await seedJob(jobId);
    const drafts = db.collection('examConversions').doc(jobId).collection('questions');
    await drafts.doc('005').set({ order: 5, label: '5', text: 'eski', editedBy: 'admin-1' });
    await drafts.doc('001').set({ order: 1, label: '1', text: 'eski', editedBy: 'admin-1' });
    await upload(`questionFigures/${jobId}/005-1.jpg`, await pageImage(), 'image/jpeg');
    const { deps } = makeDeps();
    assert.equal((await pipeline.processExamConversionHandler(deps, { jobId })).outcome, 'ready');
    const ids = (await draftDocs(jobId)).map((draft) => draft.id);
    assert.deepEqual(ids, ['001', '002']);
    assert.equal((await draftDocs(jobId))[0].editedBy, undefined);
    assert.deepEqual(await figureNames(jobId), [`questionFigures/${jobId}/002-1.jpg`]);
  });

  test('a PDF goes to the model whole; without a rasteriser its figures stay pending and need review', async () => {
    const jobId = 'exam-pdf';
    const storagePath = await upload('pdfs/exam-pdf.pdf', Buffer.from(fakePdf(2)), 'application/pdf');
    await seedJob(jobId, { kind: 'PDF', files: [{ storagePath, order: 0 }] });
    const { deps, fakes } = makeDeps();
    assert.equal((await pipeline.processExamConversionHandler(deps, { jobId })).outcome, 'ready');
    const [call] = fakes.gemini.calls;
    assert.equal(call.pageCount, 2);
    assert.deepEqual(call.files.map((file) => file.mimeType), ['application/pdf']);
    const second = (await draftDocs(jobId))[1];
    assert.deepEqual(second.figures, []);
    assert.deepEqual(second.pendingFigures, [{ index: 1, page: 2, box: [400, 428, 600, 571] }]);
    assert.equal(second.needsReview, true);
    assert.equal(second.hasFigure, true);
    assert.deepEqual(await figureNames(jobId), []);
  });

  test('with an injected PDF rasteriser the figure is cropped from the rendered page', async () => {
    const jobId = 'exam-pdf-rendered';
    const storagePath = await upload('pdfs/exam-pdf-rendered.pdf', Buffer.from(fakePdf(2)), 'application/pdf');
    await seedJob(jobId, { kind: 'PDF', files: [{ storagePath, order: 0 }] });
    const rendered = [];
    const page = await pageImage();
    const { deps } = makeDeps({
      pdf: { pageCount: async () => 2, renderPage: async (_bytes, pageIndex) => { rendered.push(pageIndex); return page; } },
    });
    assert.equal((await pipeline.processExamConversionHandler(deps, { jobId })).outcome, 'ready');
    assert.deepEqual(rendered, [1]);
    const second = (await draftDocs(jobId))[1];
    assert.equal(second.pendingFigures, undefined);
    assert.equal(second.figures[0].storagePath, `questionFigures/${jobId}/002-1.jpg`);
  });

  test('a figure on a page the exam does not have is rejected as invalid output', async () => {
    const jobId = 'exam-bad-page';
    await seedJob(jobId);
    const output = { questions: [question('1', { figures: [{ page: 9, box: [0, 0, 100, 100] }] })], unreadable: [] };
    const { deps } = makeDeps({ outputs: [output] });
    await assert.rejects(pipeline.processExamConversionHandler(deps, { jobId }), (error) => error.code === 'bad-figure');
  });
});

describe('task queue options', () => {
  test('one 30-minute attempt, bounded retries and concurrency, europe-west1', () => {
    const options = pipeline.TASK_QUEUE_OPTIONS;
    assert.equal(options.region, 'europe-west1');
    assert.ok(options.timeoutSeconds <= 1800);
    assert.ok(options.retryConfig.maxAttempts >= 2);
    assert.ok(options.rateLimits.maxConcurrentDispatches >= 1 && options.rateLimits.maxConcurrentDispatches <= 5);
    assert.ok(pipeline.LEASE_MS > options.timeoutSeconds * 1000);
  });
});

describe('processExamConversion — one question (K8 draft, K15 published)', () => {
  const NEW_TWO = {
    questions: [question('2', {
      text: 'Yeni soru 2: $x^3$ türevini alınız.',
      figures: [{ page: 2, box: [400, 428, 600, 571] }],
      confidence: 0.95,
    })],
    unreadable: [],
  };

  const oldDraft = (order, overrides = {}) => ({
    schemaVersion: 1, order, label: String(order), text: `Eski soru ${order}`, speech: `Eski soru ${order}`, choices: [],
    figures: [], answer: { text: '1' }, solution: [], topics: [], difficulty: 2, hasFigure: false, confidence: 0.5,
    needsReview: true, provider: 'gemini', modelId: 'fake-gemini-model', promptVersion: 1, generatedAt: NOW, ...overrides,
  });

  async function seedReadyJob(jobId, overrides = {}) {
    await seedJob(jobId, {
      status: 'ready', attempts: 1, model: { provider: 'gemini', id: 'fake-gemini-model' }, usage: null,
      questionCount: 2, needsReviewCount: 2, ...overrides,
    });
    const drafts = db.collection('examConversions').doc(jobId).collection('questions');
    await drafts.doc('001').set(oldDraft(1));
    await drafts.doc('002').set(oldDraft(2, { editedBy: 'admin-1', figures: [{ storagePath: `questionFigures/${jobId}/002-2.jpg` }] }));
    await upload(`questionFigures/${jobId}/002-2.jpg`, await pageImage(), 'image/jpeg');
    await upload(`questionFigures/${jobId}/001-1.jpg`, await pageImage(), 'image/jpeg');
  }

  test('the provider instruction names the one question; the whole-exam instruction is unchanged', () => {
    const whole = common.examInstruction({ kind: 'JPG', pageCount: 3 });
    assert.match(whole, /Convert and solve every question/);
    const one = common.examInstruction({ kind: 'JPG', pageCount: 3, focus: { label: '2b', order: 3 } });
    assert.match(one, /ONLY the question labelled "2b"/);
    assert.match(one, /question number 3/);
    assert.match(one, /exactly one entry/);
    const request = claude.buildClaudeRequest({ files: [], kind: 'JPG', pageCount: 3, focus: { label: '2b', order: 3 } });
    assert.equal(request.system, SYSTEM_PROMPT);
    assert.match(request.messages[0].content.at(-1).text, /"2b"/);
    assert.match(gemini.buildGeminiRequest({ files: [], kind: 'PDF', pageCount: 3, focus: { label: '4', order: 4 } }).contents[0].parts.at(-1).text, /"4"/);
  });

  test('a draft question is rewritten with the chosen provider; the rest of the job is untouched', async () => {
    const jobId = 'exam-one-draft';
    await seedReadyJob(jobId);
    const { deps, fakes, notices } = makeDeps({ outputs: [NEW_TWO] });

    const result = await pipeline.processExamConversionHandler(deps, { jobId, order: 2, provider: 'claude', target: 'draft' });
    assert.equal(result.outcome, 'ready');
    assert.equal(fakes.gemini.calls.length, 0);
    assert.equal(fakes.claude.calls.length, 1);
    assert.deepEqual(fakes.claude.calls[0].focus, { label: '2', order: 2 });
    assert.equal(fakes.claude.calls[0].pageCount, 2);

    const [first, second] = await draftDocs(jobId);
    assert.equal(first.text, 'Eski soru 1', 'other drafts are untouched');
    assert.equal(second.order, 2);
    assert.equal(second.label, '2');
    assert.match(second.text, /^Yeni soru 2/);
    assert.equal(second.provider, 'claude');
    assert.equal(second.modelId, 'fake-claude-model');
    assert.equal(second.needsReview, false);
    assert.equal(second.editedBy, undefined, 'the new draft replaces the edited one');
    assert.equal(second.regenerationLeaseUntil, undefined);
    assert.deepEqual(second.figures.map((figure) => figure.storagePath), [`questionFigures/${jobId}/002-1.jpg`]);
    assert.deepEqual(await figureNames(jobId), [`questionFigures/${jobId}/001-1.jpg`, `questionFigures/${jobId}/002-1.jpg`]);

    const job = await jobDoc(jobId);
    assert.equal(job.status, 'ready');
    assert.equal(job.attempts, 1, 'a question run is not a job attempt');
    assert.deepEqual(job.model, { provider: 'gemini', id: 'fake-gemini-model' }, 'the job keeps its whole-exam provider');
    assert.equal(job.needsReviewCount, 1);
    const cost = usage.costUsd('claude', { inputTokens: 6000, outputTokens: 4000 });
    assert.deepEqual(job.usage, { inputTokens: 6000, outputTokens: 4000, costUsd: cost }, 'usage starts from a null map');
    const month = await usageDoc();
    assert.equal(month.runs, 1);
    assert.equal(month.byProvider.claude.costUsd, cost);
    assert.deepEqual(notices, []);
  });

  test('a published question is rewritten and put live under its permanent id', async () => {
    const jobId = 'exam-e-pub';
    await seedReadyJob(jobId, { status: 'published', publishedExamId: 'e-pub' });
    await db.collection('exams').doc('e-pub').set({ status: 'published', format: 'structured', conversionJobId: jobId });
    const keys = { subjectId: 'mat', courseId: 'c1', universityId: 'u1', facultyId: 'f1', departmentId: 'd1', examType: 'final', year: 2019 };
    await db.collection('questions').doc('e-pub-002').set({ examId: 'e-pub', order: 2, text: 'Eski soru 2', answer: { text: '1' }, ...keys });
    const { deps } = makeDeps({ outputs: [NEW_TWO] });

    const result = await pipeline.processExamConversionHandler(deps, { jobId, order: 2, provider: 'gemini', target: 'published' });
    assert.equal(result.outcome, 'published');
    assert.equal(result.questionId, 'e-pub-002');
    const live = (await db.collection('questions').doc('e-pub-002').get()).data();
    assert.match(live.text, /^Yeni soru 2/);
    assert.equal(live.subjectId, 'mat', 'the query keys (and so the pools) are kept');
    assert.equal(live.year, 2019);
    assert.deepEqual(live.figures.map((figure) => figure.storagePath), [`questionFigures/${jobId}/002-1.jpg`]);
    assert.equal((await jobDoc(jobId)).status, 'published');
  });

  test('discarded, mismatched or missing targets are skipped without a model run', async () => {
    const { deps, fakes } = makeDeps({ outputs: [NEW_TWO] });
    await seedReadyJob('exam-gone-1', { status: 'discarded' });
    const discarded = await pipeline.processExamConversionHandler(deps, { jobId: 'exam-gone-1', order: 2, provider: 'claude', target: 'draft' });
    assert.deepEqual(discarded, { outcome: 'skipped', reason: 'status-discarded' });
    assert.equal((await draftDocs('exam-gone-1'))[1].text, 'Eski soru 2');

    await seedReadyJob('exam-pub-2', { status: 'published' });
    assert.equal((await pipeline.processExamConversionHandler(deps, { jobId: 'exam-pub-2', order: 1, provider: 'claude', target: 'draft' })).reason, 'status-published');
    assert.equal((await pipeline.processExamConversionHandler(deps, { jobId: 'exam-pub-2' })).reason, 'status-published', 'a whole run never touches a published job');
    await seedReadyJob('exam-ready-3');
    assert.equal((await pipeline.processExamConversionHandler(deps, { jobId: 'exam-ready-3', order: 1, provider: 'claude', target: 'published' })).reason, 'status-ready');
    assert.equal((await pipeline.processExamConversionHandler(deps, { jobId: 'exam-ready-3', order: 9, provider: 'claude', target: 'draft' })).reason, 'missing-draft');
    assert.equal((await pipeline.processExamConversionHandler(deps, { jobId: 'exam-ready-3', order: 1, provider: 'openai', target: 'draft' })).reason, 'no-provider');
    assert.equal((await pipeline.processExamConversionHandler(deps, { jobId: 'exam-ready-3', order: 1, provider: 'claude', target: 'x' })).reason, 'bad-target');
    assert.equal(fakes.claude.calls.length + fakes.gemini.calls.length, 0);
  });

  test('over the monthly cap the request is dropped with the month\'s single budget notice', async () => {
    await db.collection('aiUsage').doc(MONTH).set({ month: MONTH, costUsd: 49.99 });
    await seedReadyJob('exam-capped-q');
    const { deps, fakes, notices, enqueued } = makeDeps({ outputs: [NEW_TWO] });
    const result = await pipeline.processExamConversionHandler(deps, { jobId: 'exam-capped-q', order: 2, provider: 'claude', target: 'draft' });
    assert.equal(result.reason, 'over-cap');
    assert.equal(fakes.claude.calls.length, 0);
    assert.equal(notices.length, 1);
    assert.equal(notices[0].trigger, TRIGGERS.conversionBudgetExceeded);
    assert.equal(notices[0].month, MONTH);
    assert.deepEqual(enqueued, []);
    assert.equal((await draftDocs('exam-capped-q'))[1].text, 'Eski soru 2');
    assert.equal((await jobDoc('exam-capped-q')).status, 'ready');
  });

  test('invalid output is retried, then the draft keeps its content and records the error', async () => {
    const jobId = 'exam-one-bad';
    await seedReadyJob(jobId);
    const { deps } = makeDeps({ outputs: [{ questions: [{ label: '2', text: '' }], unreadable: [] }] });
    const payload = { jobId, order: 2, provider: 'gemini', target: 'draft' };
    await assert.rejects(pipeline.processExamConversionHandler(deps, { ...payload, retryCount: 0 }), (error) => error.code === 'missing-field');
    assert.equal((await draftDocs(jobId))[1].regenerationLeaseUntil, undefined, 'the lease is released for the retry');
    const result = await pipeline.processExamConversionHandler(deps, { ...payload, retryCount: 2 });
    assert.equal(result.outcome, 'failed');
    const second = (await draftDocs(jobId))[1];
    assert.equal(second.text, 'Eski soru 2');
    assert.match(second.regenerationError, /missing-field/);
    const job = await jobDoc(jobId);
    assert.equal(job.status, 'ready');
    assert.equal(job.usage.inputTokens, 12000, 'both billed runs are counted');
  });

  test('a regeneration already running is not run twice', async () => {
    const jobId = 'exam-one-leased';
    await seedReadyJob(jobId);
    await db.collection('examConversions').doc(jobId).collection('questions').doc('002')
      .update({ regenerationLeaseUntil: new Date(NOW.getTime() + 60_000) });
    const { deps, fakes } = makeDeps({ outputs: [NEW_TWO] });
    const payload = { jobId, order: 2, provider: 'gemini', target: 'draft' };
    await assert.rejects(pipeline.processExamConversionHandler(deps, { ...payload, retryCount: 0 }), (error) => error.code === 'lease-held');
    assert.deepEqual(await pipeline.processExamConversionHandler(deps, { ...payload, retryCount: 2 }), { outcome: 'skipped', reason: 'leased' });
    assert.equal(fakes.gemini.calls.length, 0);
  });
});

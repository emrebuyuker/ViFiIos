// Model ids, Vertex AI locations, generation settings and per-token prices of the two conversion providers — the one
// place to change them (owner decision K6/K9: both models run on Vertex AI with the Functions service account, no API
// keys; the admin picks the provider per action).
//
// TODO(Faz 2, live Vertex check): verify every value marked VERIFY against the Vertex AI Model Garden and the Vertex
// pricing page (https://cloud.google.com/vertex-ai/generative-ai/pricing) before the first live run. They were written
// on 13 Nov 2026 without a live call and are NOT guaranteed.
//
// Batch discounts: Anthropic's Message Batches API is not offered on Vertex AI, and Vertex batch prediction (Claude
// and Gemini both have a ~50% batch price there) needs BigQuery / Cloud Storage job plumbing. Not implemented — every
// job runs as an online request through the task queue, the one-time migration script included.
// TODO(Faz 2): check per model whether Vertex batch prediction is worth wiring for the one-time script (K12c).

export const PROVIDER_CONFIG = Object.freeze({
  claude: Object.freeze({
    // VERIFY: Vertex uses the bare first-party id for current Claude models (no @date suffix).
    modelId: 'claude-opus-5-5',
    // VERIFY: 'global' is Anthropic's recommended Vertex endpoint; a regional one (e.g. 'europe-west1') pins data
    // residency but is priced ~10% higher and must be enabled for this model. Owner decision pending.
    location: 'global',
    // Generous: ~30 questions with worked solutions plus adaptive thinking. Streaming keeps it under HTTP timeouts.
    maxOutputTokens: 64000,
    // Opus 5.5 defaults to 'medium'; solving exam questions is correctness-sensitive.
    effort: 'high',
    // VERIFY: USD per million tokens. Vertex list price assumed equal to the first-party price ($4 / $20) for the
    // global endpoint.
    pricing: Object.freeze({ tiers: Object.freeze([Object.freeze({ inputPerMTok: 4, outputPerMTok: 20 })]) }),
  }),
  gemini: Object.freeze({
    // VERIFY: the newest Gemini Pro id the installed @google/genai documents; may be GA under another id by Faz 2.
    modelId: 'gemini-3.1-pro-preview',
    // VERIFY: preview Gemini models are often served only from 'global'.
    location: 'global',
    maxOutputTokens: 65536,
    thinkingLevel: 'HIGH',
    // VERIFY: USD per million tokens, Gemini 3 Pro list price: prompts up to 200k tokens $2 / $12, above $4 / $18.
    // Thinking tokens are billed as output.
    pricing: Object.freeze({
      tiers: Object.freeze([
        Object.freeze({ upToInputTokens: 200_000, inputPerMTok: 2, outputPerMTok: 12 }),
        Object.freeze({ inputPerMTok: 4, outputPerMTok: 18 }),
      ]),
    }),
  }),
});

/**
 * Rough per-page token use for cost estimates before a run (budget check, bulk dry-run): one page image plus its
 * share of the transcription, solution and thinking. Calibrate from recorded `usage` after the first live jobs.
 */
export const ESTIMATED_TOKENS_PER_PAGE = Object.freeze({ input: 3000, output: 3000 });

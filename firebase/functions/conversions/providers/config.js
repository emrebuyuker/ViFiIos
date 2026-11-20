// Model ids, Vertex AI locations, generation settings and per-token prices of the two conversion providers — the one
// place to change them (owner decision K6/K9: both models run on Vertex AI with the Functions service account, no API
// keys; the admin picks the provider per action).
//
// Verified on 20 Nov 2026 (no live model call yet) against the vifi-831a8 Model Garden pages, the Marketplace agreement
// for Claude Opus 5.5 and the pricing page (https://cloud.google.com/model-garden/pricing, formerly
// /vertex-ai/generative-ai/pricing). Re-check ids and prices whenever a model is changed here.
//
// Batch discounts: Anthropic's Message Batches API is not offered on Vertex AI, and Vertex batch prediction (Claude
// and Gemini both have a ~50% batch price there) needs BigQuery / Cloud Storage job plumbing. Not implemented — every
// job runs as an online request through the task queue, the one-time migration script included.
// TODO(Faz 2): check per model whether Vertex batch prediction is worth wiring for the one-time script (K12c).

export const PROVIDER_CONFIG = Object.freeze({
  claude: Object.freeze({
    // Verified: Vertex uses the bare first-party id for current Claude models (no @date suffix).
    modelId: 'claude-opus-5-5',
    // 'global' is Anthropic's recommended Vertex endpoint (owner decision K18); a regional one (e.g. 'europe-west1')
    // pins data residency but is priced higher and must be enabled for this model.
    location: 'global',
    // Generous: ~30 questions with worked solutions plus adaptive thinking. Streaming keeps it under HTTP timeouts.
    maxOutputTokens: 64000,
    // Opus 5.5 defaults to 'medium'; solving exam questions is correctness-sensitive.
    effort: 'high',
    // USD per million tokens on the global endpoint. Verified: $4 input / $20 output at every context size (Marketplace
    // agreement, 20 Nov 2026).
    pricing: Object.freeze({ tiers: Object.freeze([Object.freeze({ inputPerMTok: 4, outputPerMTok: 20 })]) }),
  }),
  gemini: Object.freeze({
    // Verified: still the newest Gemini Pro on Vertex (20 Nov 2026); no GA id yet. Output limit 64K tokens.
    modelId: 'gemini-3.1-pro-preview',
    // Verified: this preview model is priced and served on 'global' only.
    location: 'global',
    maxOutputTokens: 65536,
    thinkingLevel: 'HIGH',
    // USD per million tokens. Verified: prompts up to 200k tokens $2 / $12, above $4 / $18; thinking tokens are billed
    // as output ("response and reasoning").
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

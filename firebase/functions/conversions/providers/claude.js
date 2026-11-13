// Claude Opus 5.5 on Vertex AI (`@anthropic-ai/vertex-sdk`). Auth is Google Application Default Credentials — the
// Functions service account in production — so there is no API key anywhere.
//
// One streamed Messages request per exam: the system prompt, the exam's files (PDF as a `document` block, pages as
// `image` blocks) and the shared JSON schema as a structured output (`output_config.format`), so the reply is the
// schema-shaped JSON text. Thinking is adaptive (always on for Opus 5.5); depth is set with `effort`.
//
// Not used on purpose: client-side refusal fallback middleware (it would silently answer with another model while the
// job records `claude-opus-5-5`); a refusal fails the run and the task queue retries it.

import { MODEL_OUTPUT_SCHEMA } from '../schema.js';
import { SYSTEM_PROMPT } from '../prompt.js';
import { PROVIDER_CONFIG } from './config.js';
import { ProviderError, closedSchema, examInstruction, parseJsonOutput } from './common.js';

const OUTPUT_SCHEMA = closedSchema(MODEL_OUTPUT_SCHEMA);

/** The Messages request body (exported for tests). */
export function buildClaudeRequest({ files, kind, pageCount }, config = PROVIDER_CONFIG.claude) {
  const content = files.map(({ bytes, mimeType }) => (mimeType === 'application/pdf'
    ? { type: 'document', source: { type: 'base64', media_type: 'application/pdf', data: bytes.toString('base64') } }
    : { type: 'image', source: { type: 'base64', media_type: mimeType, data: bytes.toString('base64') } }));
  content.push({ type: 'text', text: examInstruction({ kind, pageCount }) });
  return {
    model: config.modelId,
    max_tokens: config.maxOutputTokens,
    system: SYSTEM_PROMPT,
    messages: [{ role: 'user', content }],
    output_config: { effort: config.effort, format: { type: 'json_schema', schema: OUTPUT_SCHEMA } },
  };
}

/** Token usage of a final message (input includes any cache traffic, which is billed as input too). */
export function claudeUsage(message) {
  const usage = message?.usage ?? {};
  return {
    inputTokens: (usage.input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0) + (usage.cache_read_input_tokens ?? 0),
    outputTokens: usage.output_tokens ?? 0,
  };
}

/** Turns a final message into `{ output, usage }` or a `ProviderError`. */
export function readClaudeMessage(message) {
  const usage = claudeUsage(message);
  if (message?.stop_reason === 'refusal') {
    throw new ProviderError('refusal', `The model declined (${message.stop_details?.category ?? 'no category'})`, { usage });
  }
  if (message?.stop_reason === 'max_tokens') {
    throw new ProviderError('max-tokens', 'The answer hit the output token limit', { usage });
  }
  const text = (message?.content ?? []).filter((block) => block.type === 'text').map((block) => block.text).join('');
  return { output: parseJsonOutput(text, usage), usage };
}

/**
 * `client` is injectable (tests); by default an `AnthropicVertex` client for the running project is created on
 * first use, so loading this module costs nothing for the other functions.
 */
export function createClaudeProvider({ client, projectId = process.env.GCLOUD_PROJECT, config = PROVIDER_CONFIG.claude } = {}) {
  let clientPromise = client ? Promise.resolve(client) : null;
  const getClient = () => {
    clientPromise ??= import('@anthropic-ai/vertex-sdk')
      .then(({ AnthropicVertex }) => new AnthropicVertex({ projectId, region: config.location }));
    return clientPromise;
  };
  return {
    name: 'claude',
    modelId: config.modelId,
    async solveExam({ files, kind, pageCount }) {
      const anthropic = await getClient();
      let message;
      try {
        message = await anthropic.messages.stream(buildClaudeRequest({ files, kind, pageCount }, config)).finalMessage();
      } catch (error) {
        // 4xx other than 408/409/429 will not get better on retry (bad request, permission, model not enabled).
        const status = error?.status;
        const retryable = !(status >= 400 && status < 500 && ![408, 409, 429].includes(status));
        throw new ProviderError('request-failed', `Claude request failed${status ? ` (${status})` : ''}: ${error?.message ?? error}`, { retryable });
      }
      return readClaudeMessage(message);
    },
  };
}

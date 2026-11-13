// Gemini Pro on Vertex AI (`@google/genai` with `vertexai: true`). Auth is Google Application Default Credentials —
// the Functions service account in production — so there is no API key anywhere.
//
// One `generateContent` request per exam: the system prompt as `systemInstruction`, the exam's files as inline data
// and the shared JSON schema as `responseJsonSchema` with `responseMimeType: application/json`. Thinking tokens are
// billed as output and counted as such.
//
// Note: Vertex caps inline request data (~20 MB); a large scanned PDF may need a `gs://` `fileData` reference instead
// (Vertex reads the project's own bucket once its service agent has access). TODO(Faz 2): check with real exams.

import { MODEL_OUTPUT_SCHEMA } from '../schema.js';
import { SYSTEM_PROMPT } from '../prompt.js';
import { PROVIDER_CONFIG } from './config.js';
import { ProviderError, examInstruction, parseJsonOutput } from './common.js';

/** The `generateContent` parameters (exported for tests). */
export function buildGeminiRequest({ files, kind, pageCount }, config = PROVIDER_CONFIG.gemini) {
  const parts = files.map(({ bytes, mimeType }) => ({ inlineData: { mimeType, data: bytes.toString('base64') } }));
  parts.push({ text: examInstruction({ kind, pageCount }) });
  return {
    model: config.modelId,
    contents: [{ role: 'user', parts }],
    config: {
      systemInstruction: SYSTEM_PROMPT,
      responseMimeType: 'application/json',
      responseJsonSchema: MODEL_OUTPUT_SCHEMA,
      maxOutputTokens: config.maxOutputTokens,
      thinkingConfig: { thinkingLevel: config.thinkingLevel },
    },
  };
}

export function geminiUsage(response) {
  const usage = response?.usageMetadata ?? {};
  return {
    inputTokens: usage.promptTokenCount ?? 0,
    outputTokens: (usage.candidatesTokenCount ?? 0) + (usage.thoughtsTokenCount ?? 0),
  };
}

/** Turns a response into `{ output, usage }` or a `ProviderError`. */
export function readGeminiResponse(response) {
  const usage = geminiUsage(response);
  const blocked = response?.promptFeedback?.blockReason;
  if (blocked) throw new ProviderError('blocked', `The prompt was blocked (${blocked})`, { usage });
  const candidate = response?.candidates?.[0];
  const finish = candidate?.finishReason;
  if (finish === 'MAX_TOKENS') throw new ProviderError('max-tokens', 'The answer hit the output token limit', { usage });
  if (finish && finish !== 'STOP') throw new ProviderError('finish', `The model stopped early (${finish})`, { usage });
  const text = (candidate?.content?.parts ?? [])
    .filter((part) => typeof part.text === 'string' && !part.thought)
    .map((part) => part.text)
    .join('');
  return { output: parseJsonOutput(text, usage), usage };
}

/**
 * `client` is injectable (tests); by default a Vertex `GoogleGenAI` client for the running project is created on first
 * use, so loading this module costs nothing for the other functions.
 */
export function createGeminiProvider({ client, projectId = process.env.GCLOUD_PROJECT, config = PROVIDER_CONFIG.gemini } = {}) {
  let clientPromise = client ? Promise.resolve(client) : null;
  const getClient = () => {
    clientPromise ??= import('@google/genai')
      .then(({ GoogleGenAI }) => new GoogleGenAI({ vertexai: true, project: projectId, location: config.location }));
    return clientPromise;
  };
  return {
    name: 'gemini',
    modelId: config.modelId,
    async solveExam({ files, kind, pageCount }) {
      const ai = await getClient();
      let response;
      try {
        response = await ai.models.generateContent(buildGeminiRequest({ files, kind, pageCount }, config));
      } catch (error) {
        const status = error?.status ?? error?.code;
        const retryable = !(status >= 400 && status < 500 && ![408, 409, 429].includes(status));
        throw new ProviderError('request-failed', `Gemini request failed${status ? ` (${status})` : ''}: ${error?.message ?? error}`, { retryable });
      }
      return readGeminiResponse(response);
    },
  };
}

// What both provider clients share: the error type, the user-turn instruction and JSON parsing.
//
// Provider interface (claude.js, gemini.js, and the fakes in tests):
//   { name, modelId, solveExam({ files: [{ bytes: Buffer, mimeType }], kind, pageCount }) →
//       { output: <parsed JSON, unvalidated>, usage: { inputTokens, outputTokens } } }
// `files` are in exam order; a PDF's pages continue the page count. Validation (`validateModelOutput`) is the
// pipeline's job, so a fake can return anything.

/** A provider failure. `usage` is set when the model answered (and billed) but the answer was unusable. */
export class ProviderError extends Error {
  constructor(code, message, { retryable = true, usage } = {}) {
    super(message);
    this.name = 'ProviderError';
    this.code = code;
    this.retryable = retryable;
    if (usage) this.usage = usage;
  }
}

/** The user turn after the files: tells the model how many pages there are and asks for the schema. */
export function examInstruction({ kind, pageCount }) {
  const what = kind === 'PDF' ? 'PDF' : 'page images';
  return `These ${what} are one exam with ${pageCount} page(s) in total, numbered 1–${pageCount} in the order given. `
    + 'Convert and solve every question as instructed and return the JSON object.';
}

/** Parses the model's JSON text; an unparsable answer is a retryable failure that was still billed. */
export function parseJsonOutput(text, usage) {
  if (typeof text !== 'string' || text.trim() === '') {
    throw new ProviderError('empty-response', 'The model returned no text', { usage });
  }
  try {
    return JSON.parse(text);
  } catch {
    throw new ProviderError('invalid-json', 'The model returned text that is not JSON', { usage });
  }
}

/**
 * The schema with `additionalProperties: false` on every object — required by Claude's structured outputs (strict
 * JSON-schema mode). The authoritative `MODEL_OUTPUT_SCHEMA` itself stays untouched.
 */
export function closedSchema(schema) {
  if (Array.isArray(schema)) return schema.map(closedSchema);
  if (!schema || typeof schema !== 'object') return schema;
  const copy = Object.fromEntries(Object.entries(schema).map(([key, value]) => [key, closedSchema(value)]));
  if (copy.type === 'object') copy.additionalProperties = false;
  return copy;
}

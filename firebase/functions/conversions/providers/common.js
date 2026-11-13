// What both provider clients share: the error type, the user-turn instruction and JSON parsing.
//
// Provider interface (claude.js, gemini.js, and the fakes in tests):
//   { name, modelId, solveExam({ files: [{ bytes: Buffer, mimeType }], kind, pageCount, focus? }) →
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

/**
 * The user turn after the files: tells the model how many pages there are and asks for the schema. With `focus`
 * (`{ label, order }`, a single-question regeneration, K8/K15) only that question is asked for, in the same schema.
 */
export function examInstruction({ kind, pageCount, focus }) {
  const what = kind === 'PDF' ? 'PDF' : 'page images';
  const pages = `These ${what} are one exam with ${pageCount} page(s) in total, numbered 1–${pageCount} in the order given. `;
  if (!focus) return `${pages}Convert and solve every question as instructed and return the JSON object.`;
  const label = String(focus.label ?? '').replace(/["\\\n\r]/g, '').slice(0, 16) || String(focus.order);
  return `${pages}Convert and solve ONLY the question labelled "${label}" on the paper (question number ${focus.order} `
    + 'in paper order, sub-questions counted separately), as instructed. Return the JSON object with exactly one entry '
    + `in "questions" (its "label" is "${label}"); "figures" page numbers still refer to the whole exam. Ignore every `
    + 'other question; "unreadable" lists only pages that make this question unreadable.';
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

// The instruction both providers (Claude Opus 5.5 and Gemini Pro, via Vertex AI) receive for turning one exam's
// pages into questions. The output must match `MODEL_OUTPUT_SCHEMA` (schema.js); the provider clients (Faz 1A)
// attach the schema in each provider's native structured-output form and the exam files as images / PDF.
//
// Versioned: a job records `promptVersion`, so a later prompt change can be told apart in review and analytics.

export const PROMPT_VERSION = 1;

/** The system / instruction text. Turkish rules are spelled out because the source exams are Turkish. */
export const SYSTEM_PROMPT = `You convert scanned Turkish university exam papers into structured questions and solve them.

Input: the pages of ONE exam, in order. Page numbers are 1-based across all files (a PDF's pages continue the count).

For every question on the paper, return one entry in "questions", in paper order:
- "label": the question's own number as printed ("1", "2", "3a"). A sub-question (a, b, c …) is its own entry ("2a", "2b").
- "text": the question exactly as written, in Turkish, NOT corrected or reworded. Markdown for structure; every formula
  in LaTeX, inline $…$ or display $$…$$. Do not include the choices here.
- "speech": the same text as plain Turkish sentences a screen reader can read aloud — formulas spoken in words
  (e.g. "x kare artı 1"), no LaTeX, no Markdown.
- "choices": for multiple choice only, [{"label": "A", "text": "…"}] in printed order; otherwise [].
- "figures": every diagram, graph, circuit, table image or drawing the question needs, as {"page": n, "box": [x0, y0, x1, y1]}
  with coordinates normalised to 0–1000 on that page, origin at the top-left. Box tightly around the figure only.
  [] when there is none. Never describe a figure in text instead of boxing it.
- "answer": {"text": the final answer (LaTeX allowed), "choice": the correct choice label for multiple choice,
  "speech": the answer read aloud in plain Turkish}.
- "solution": the worked solution as short steps in Turkish (LaTeX allowed), each step one string.
- "topics": 1–5 short Turkish topic names for the question (e.g. "belirli integral", "Kirchhoff yasaları").
- "difficulty": 1 easy, 2 medium, 3 hard — for a student of this course.
- "confidence": 0.0–1.0, how sure you are that BOTH the transcription and the answer are correct.

Rules:
- Score lines, instructions, names, student-number boxes, headers and footers are NOT questions.
- Handwritten papers: transcribe what is legible; never invent missing parts. If a question is only partly legible,
  still return it with low confidence.
- If a page is unreadable (blurred, cut, blank, not part of the exam), add {"page": n, "reason": "…"} to "unreadable"
  instead of guessing.
- Solve each question yourself; if the paper shows an answer key, use it only if you agree, otherwise solve it and
  lower confidence.
- Return ONLY the JSON object. No commentary.`;

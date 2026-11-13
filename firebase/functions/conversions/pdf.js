// The PDF rasteriser of the conversion pipeline (owner decision K17, 13 Nov 2026): `pdfjs-dist` (Apache-2.0) draws a
// PDF page onto an `@napi-rs/canvas` (MIT) canvas, so a PDF question's figure boxes are cropped from the rendered
// page exactly like a photographed page's (images.js `normalizePageImage` → `cropFigure`). It also gives the exact
// page count, which the regex fallback in images.js (`pdfPageCount`) cannot read from compressed object streams.
//
// Wired as `deps.pdf = livePdf()` (index.js → pipeline.js `loadExam` / `cropFor`). Both libraries are loaded on first
// use, so a function instance that never sees a PDF never pays for them. Any failure here is non-fatal for the
// pipeline: a failed count falls back to `pdfPageCount`, a failed render keeps the figure as `pendingFigures`.
//
// Page geometry: the model reads the PDF itself and returns 0–1000 boxes over each page as displayed (the page's
// `/Rotate` applied); pdf.js viewports apply the same rotation, so the rendered image and the boxes agree.

import { createRequire } from 'node:module';
import path from 'node:path';

/** Render resolution. 150 DPI keeps small figure labels legible after the long-edge cap of `normalizePageImage`. */
export const PDF_RENDER_DPI = 150;
/** Hard cap on the rendered long edge (an A0 poster page at 150 DPI would otherwise be ~7000 px). */
export const PDF_RENDER_MAX_EDGE = 3000;
/** Hard cap on rendered pixels (memory: a 3000 × 3000 RGBA canvas is ~36 MB). */
export const PDF_RENDER_MAX_PIXELS = 3000 * 3000;

const require = createRequire(import.meta.url);

let pdfjsModule;
async function pdfjs() {
  // The legacy build is pdf.js's supported entry point for Node.js.
  pdfjsModule ??= await import('pdfjs-dist/legacy/build/pdf.mjs');
  return pdfjsModule;
}

/** pdf.js's bundled resources (non-embedded standard fonts, CMaps, ICC profiles, wasm decoders), as directory URLs. */
function resourceDirs() {
  const root = path.dirname(require.resolve('pdfjs-dist/package.json'));
  const dir = (name) => `${path.join(root, name)}${path.sep}`;
  return {
    standardFontDataUrl: dir('standard_fonts'),
    cMapUrl: dir('cmaps'),
    cMapPacked: true,
    iccUrl: dir('iccs'),
    wasmUrl: dir('wasm'),
  };
}

/**
 * Runs `work(document)` on an opened PDF (a private copy of the bytes: pdf.js detaches the buffer it is given) and
 * always destroys the loading task, which frees the document and its fake worker.
 */
async function withDocument(bytes, work) {
  const { getDocument } = await pdfjs();
  const task = getDocument({
    data: new Uint8Array(bytes),
    ...resourceDirs(),
    isEvalSupported: false,
    disableFontFace: true,
    useSystemFonts: false,
    verbosity: 0,
  });
  try {
    return await work(await task.promise);
  } finally {
    await task.destroy();
  }
}

/** The scale for a page whose unscaled (72 DPI) viewport is `width` × `height`: the DPI, then the caps. */
export function renderScale(width, height) {
  const base = PDF_RENDER_DPI / 72;
  const long = Math.max(width, height) * base;
  const pixels = width * height * base * base;
  const byEdge = long > PDF_RENDER_MAX_EDGE ? PDF_RENDER_MAX_EDGE / long : 1;
  const byPixels = pixels > PDF_RENDER_MAX_PIXELS ? Math.sqrt(PDF_RENDER_MAX_PIXELS / pixels) : 1;
  return base * Math.min(byEdge, byPixels);
}

/** The exact number of pages; throws for bytes pdf.js cannot open. */
export async function renderedPdfPageCount(bytes) {
  return withDocument(bytes, (document) => document.numPages);
}

/**
 * Page `pageIndex` (0-based) as a PNG buffer on a white background, at `PDF_RENDER_DPI` within the size caps. Throws
 * for a page outside the document or a PDF pdf.js cannot draw.
 */
export async function renderPdfPage(bytes, pageIndex) {
  return withDocument(bytes, async (document) => {
    if (!Number.isInteger(pageIndex) || pageIndex < 0 || pageIndex >= document.numPages) {
      throw new RangeError(`Page ${pageIndex + 1} is outside 1…${document.numPages}`);
    }
    const page = await document.getPage(pageIndex + 1);
    const unscaled = page.getViewport({ scale: 1 });
    const viewport = page.getViewport({ scale: renderScale(unscaled.width, unscaled.height) });
    const width = Math.max(1, Math.round(viewport.width));
    const height = Math.max(1, Math.round(viewport.height));
    const { createCanvas } = require('@napi-rs/canvas');
    const canvas = createCanvas(width, height);
    const context = canvas.getContext('2d');
    context.fillStyle = '#ffffff';
    context.fillRect(0, 0, width, height);
    await page.render({ canvasContext: context, canvas, viewport, background: '#ffffff' }).promise;
    page.cleanup();
    return canvas.toBuffer('image/png');
  });
}

/** The pipeline's `deps.pdf` (pipeline.js). */
export function livePdf() {
  return { pageCount: renderedPdfPageCount, renderPage: renderPdfPage };
}

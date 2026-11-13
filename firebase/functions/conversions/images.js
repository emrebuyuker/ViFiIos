// Page and figure image handling for the conversion pipeline (`sharp`): page images are normalised once (EXIF
// rotation applied, long edge ≤ MODEL_IMAGE_MAX, JPEG) — the model sees exactly that image, so the normalised 0–1000
// figure boxes it returns map onto it — and figures are cropped from it, JPEG, long edge ≤ FIGURE_MAX.
//
// PDFs: the prebuilt `sharp` (libvips) has no PDF loader, so a PDF page can only be cropped when a rasteriser is
// injected (`deps.pdf.renderPage`, see pipeline.js). Without one the figure boxes are kept on the draft as
// `pendingFigures` and the question is flagged for review.

export const MODEL_IMAGE_MAX = 2048;
export const FIGURE_MAX = 1200;
export const JPEG_QUALITY = 85;
/** Extra margin around a figure box, in the 0–1000 space (the model boxes "tightly"). */
export const FIGURE_PADDING = 8;

let sharpModule;
async function sharp() {
  sharpModule ??= (await import('sharp')).default;
  return sharpModule;
}

/** A page image ready for the model and for cropping: `{ bytes, width, height }` (JPEG). */
export async function normalizePageImage(bytes) {
  const make = await sharp();
  const { data, info } = await make(bytes, { failOn: 'none' })
    .rotate()
    .resize({ width: MODEL_IMAGE_MAX, height: MODEL_IMAGE_MAX, fit: 'inside', withoutEnlargement: true })
    .jpeg({ quality: JPEG_QUALITY, mozjpeg: true })
    .toBuffer({ resolveWithObject: true });
  return { bytes: data, width: info.width, height: info.height };
}

/** The pixel rectangle of a 0–1000 box on a `width` × `height` image, padded and clamped; null when degenerate. */
export function pixelRect(box, width, height, padding = FIGURE_PADDING) {
  const [x0, y0, x1, y1] = box;
  const clamp = (value) => Math.min(1000, Math.max(0, value));
  const left = Math.floor((clamp(x0 - padding) / 1000) * width);
  const top = Math.floor((clamp(y0 - padding) / 1000) * height);
  const right = Math.ceil((clamp(x1 + padding) / 1000) * width);
  const bottom = Math.ceil((clamp(y1 + padding) / 1000) * height);
  const rect = { left, top, width: Math.min(width, right) - left, height: Math.min(height, bottom) - top };
  return rect.width >= 2 && rect.height >= 2 ? rect : null;
}

/** Crops one figure from a normalised page: `{ bytes, width, height }` (JPEG, long edge ≤ FIGURE_MAX). */
export async function cropFigure(page, box) {
  const rect = pixelRect(box, page.width, page.height);
  if (!rect) throw new Error('The figure box is empty on this page');
  const make = await sharp();
  const { data, info } = await make(page.bytes)
    .extract(rect)
    .resize({ width: FIGURE_MAX, height: FIGURE_MAX, fit: 'inside', withoutEnlargement: true })
    .jpeg({ quality: JPEG_QUALITY, mozjpeg: true })
    .toBuffer({ resolveWithObject: true });
  return { bytes: data, width: info.width, height: info.height };
}

/**
 * Best-effort PDF page count without a PDF library: the largest `/Count` of a `/Type /Pages` node, else the number
 * of `/Type /Page` objects. Returns null when neither is visible (e.g. everything inside compressed object streams).
 */
export function pdfPageCount(bytes) {
  const text = Buffer.from(bytes).toString('latin1');
  let max = 0;
  for (const match of text.matchAll(/obj\b([\s\S]*?)endobj/g)) {
    const body = match[1];
    if (!/\/Type\s*\/Pages\b/.test(body)) continue;
    const count = /\/Count\s+(\d+)/.exec(body);
    if (count) max = Math.max(max, Number(count[1]));
  }
  if (max > 0) return max;
  const pages = text.match(/\/Type\s*\/Page(?![A-Za-z])/g)?.length ?? 0;
  return pages > 0 ? pages : null;
}

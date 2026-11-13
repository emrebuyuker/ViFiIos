// Removing archive page files (`imagess/`, `pdfs/`) that no exam uses any more (owner decisions K20, K22):
// - K20: a discarded submission job (`sub-<id>`) leaves behind the copies its first approval made;
// - K22: a duplicate submission's second approval replaces the existing exam's `files`, so the previous pages go.
//
// A file is deleted only when no `exams` document references it. The check is a query, not a full scan:
// `files array-contains-any [{ storagePath, order: 0 }, …]` over the first `REFERENCE_ORDERS` positions (+ the
// position the caller knew), because Firestore matches array entries as whole maps (`{ storagePath, order }`, the
// shape every writer uses). Best effort: every failure is logged and the file is kept; nothing here throws.

import * as logger from 'firebase-functions/logger';

/** Only public archive page files are ever deleted here (never `pending/`, figures or anything else). */
export const ARCHIVE_FILE_PATTERN = /^(imagess|pdfs)\/[^/]+$/;
/** `array-contains-any` takes at most 30 values: positions 0…29 are checked (an exam has far fewer pages). */
export const REFERENCE_ORDERS = 30;

/** `[{ storagePath, order }]` entries with an archive path; anything else is dropped. Duplicates are merged. */
export function archiveFileEntries(files) {
  const seen = new Map();
  for (const file of Array.isArray(files) ? files : []) {
    const storagePath = typeof file?.storagePath === 'string' ? file.storagePath : '';
    if (!ARCHIVE_FILE_PATTERN.test(storagePath) || seen.has(storagePath)) continue;
    seen.set(storagePath, Number.isInteger(file.order) ? file.order : 0);
  }
  return [...seen].map(([storagePath, order]) => ({ storagePath, order }));
}

/** Whether any exam document lists `storagePath` (at the known `order` or any of the first positions). */
export async function isReferencedByExam(db, { storagePath, order }) {
  const orders = [...new Set([order, ...Array.from({ length: REFERENCE_ORDERS }, (_, k) => k)])].slice(0, REFERENCE_ORDERS);
  const snapshot = await db.collection('exams')
    .where('files', 'array-contains-any', orders.map((position) => ({ storagePath, order: position })))
    .limit(1)
    .get();
  return !snapshot.empty;
}

/**
 * Deletes the archive files among `files` that no exam references (`except` paths are never touched).
 *
 * @param {{ db: object, bucket: { file: Function } }} deps
 * @returns {Promise<{ deleted: string[], kept: string[] }>}
 */
export async function deleteUnreferencedArchiveFiles(deps, files, { except = [] } = {}) {
  const skip = new Set(except);
  const deleted = [];
  const kept = [];
  for (const entry of archiveFileEntries(files)) {
    if (skip.has(entry.storagePath)) continue;
    try {
      if (await isReferencedByExam(deps.db, entry)) {
        kept.push(entry.storagePath);
        continue;
      }
      await deps.bucket.file(entry.storagePath).delete({ ignoreNotFound: true });
      deleted.push(entry.storagePath);
    } catch (error) {
      kept.push(entry.storagePath);
      logger.warn('Could not remove an archive file', { storagePath: entry.storagePath, error: error?.message ?? String(error) });
    }
  }
  return { deleted, kept };
}

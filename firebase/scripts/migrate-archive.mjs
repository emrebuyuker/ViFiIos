// One-time migration of the Realtime Database exam archive into Cloud Firestore (migration item #9).
//
// The transform (`buildFirestoreDocs`) is PURE and unit-tested; the CLI `main()` is a thin writer. Nothing runs
// live from the tests. The actual run happens at the cutover (item #10): first a dry run (counts), then
// `--apply` against the emulator to rehearse, then `--apply` against production — each with explicit approval.
//
// Shape read (RTDB export): `Universitiess/<uni>/<fac>/<dep>/<lesson>/<exam>/<JPG|PDF>/<pushId>/downloadURL`,
// each node also carrying its own name leaf (uniname/fakname/bolname/lessonname/imagename).
//
// Shape written (contract with FirestoreArchiveParser):
//   catalogNodes/<id>  { level, name, parentId, status:'published', childCount, slug, source:'migration' }
//   exams/<id>         { title, universityId, facultyId, departmentId, courseId, <names>, kind, files:[{storagePath,order}],
//                        status:'published', source:'migration', isLocked:false, coinCost:0, counts{views,downloads,unlocks}, sortKey }
//
// Canonical ids are composite slugs (`uniSlug__facSlug__…`), so `parentId == <parent id>` lists a level and the
// university slug matches the profile's `universityId` (same `slug`), keeping segmentation joins intact.

import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { slug } from './slug.mjs';

const ROOT_KEY = 'Universitiess';
const LEAF = { university: 'uniname', faculty: 'fakname', department: 'bolname', course: 'lessonname', exam: 'imagename' };
// Non-university keys seen at the archive root in the live data; never migrated.
const JUNK_KEYS = new Set(['poc', 'Announcements', '2DfjkeJxHJTkdhz5VNVwFJzAeuD']);
const KINDS = ['JPG', 'PDF']; // images win when an exam has both

/**
 * Transforms the `Universitiess` object into Firestore documents. Pure and deterministic (same input → same
 * ids and data), so re-running the write with `set()` is idempotent. Empty branches and junk are pruned.
 */
export function buildFirestoreDocs(universities) {
  const out = { catalogNodes: [], exams: [] };

  for (const [uniName, uniNode] of objectEntries(universities, null, JUNK_KEYS)) {
    const uniId = slug(uniName);
    let facCount = 0;

    for (const [facName, facNode] of objectEntries(uniNode, LEAF.university)) {
      const facId = `${uniId}__${slug(facName)}`;
      let depCount = 0;

      for (const [depName, depNode] of objectEntries(facNode, LEAF.faculty)) {
        const depId = `${facId}__${slug(depName)}`;
        let courseCount = 0;

        for (const [courseName, courseNode] of objectEntries(depNode, LEAF.department)) {
          const courseId = `${depId}__${slug(courseName)}`;
          const ancestry = { uniId, facId, depId, courseId, uniName, facName, depName, courseName };
          let examCount = 0;

          for (const [examName, examNode] of objectEntries(courseNode, LEAF.course)) {
            const extracted = extractFiles(examNode);
            if (!extracted) continue; // an exam with no usable files is dropped
            out.exams.push({ id: `${courseId}__${slug(examName)}`, data: examDoc(examName, extracted, ancestry) });
            examCount += 1;
          }

          if (examCount === 0) continue; // prune an empty course
          out.catalogNodes.push({ id: courseId, data: catalogDoc('course', courseName, depId, examCount) });
          courseCount += 1;
        }

        if (courseCount === 0) continue;
        out.catalogNodes.push({ id: depId, data: catalogDoc('department', depName, facId, courseCount) });
        depCount += 1;
      }

      if (depCount === 0) continue;
      out.catalogNodes.push({ id: facId, data: catalogDoc('faculty', facName, uniId, depCount) });
      facCount += 1;
    }

    if (facCount === 0) continue;
    out.catalogNodes.push({ id: uniId, data: catalogDoc('university', uniName, '', facCount) });
  }

  return out;
}

// MARK: - Transform helpers

/** Object-valued children of `node`, excluding its own name leaf and any junk keys. */
function objectEntries(node, leafKey, junkKeys = new Set()) {
  if (!node || typeof node !== 'object') return [];
  return Object.entries(node).filter(
    ([key, value]) => key !== leafKey && !junkKeys.has(key) && value !== null && typeof value === 'object'
  );
}

function catalogDoc(level, name, parentId, childCount) {
  return { level, name, parentId, status: 'published', childCount, slug: slug(name), source: 'migration' };
}

function examDoc(examName, extracted, a) {
  return {
    title: examName,
    universityId: a.uniId,
    facultyId: a.facId,
    departmentId: a.depId,
    courseId: a.courseId,
    universityName: a.uniName,
    facultyName: a.facName,
    departmentName: a.depName,
    courseName: a.courseName,
    kind: extracted.kind,
    files: extracted.files,
    status: 'published',
    source: 'migration',
    isLocked: false,
    coinCost: 0,
    counts: { views: 0, downloads: 0, unlocks: 0 },
    sortKey: examName,
  };
}

/** The files of an exam, images winning when both kinds are present; `null` when there are none. */
function extractFiles(examNode) {
  const groups = {};
  for (const [key, value] of Object.entries(examNode)) {
    const normalised = key.trim().toUpperCase(); // tolerate stray casing / trailing spaces (e.g. "PDF ")
    if ((normalised === 'JPG' || normalised === 'PDF') && value && typeof value === 'object') {
      groups[normalised] = value;
    }
  }
  for (const kind of KINDS) {
    if (!groups[kind]) continue;
    const files = Object.entries(groups[kind])
      .filter(([, file]) => file && typeof file === 'object' && typeof file.downloadURL === 'string')
      .sort(([a], [b]) => comparePushIds(a, b))
      .map(([, file]) => storagePathFromURL(file.downloadURL))
      .filter((path) => path !== null)
      .map((storagePath, order) => ({ storagePath, order }));
    if (files.length > 0) return { kind, files };
  }
  return null;
}

/** Push ids sort chronologically; numeric array indices sort numerically (as the RTDB parser does). */
function comparePushIds(a, b) {
  if (/^\d+$/.test(a) && /^\d+$/.test(b)) return Number(a) - Number(b);
  return a < b ? -1 : a > b ? 1 : 0;
}

/** The storage object path from a Firebase download URL (`…/o/<url-encoded path>?…` → decoded). */
export function storagePathFromURL(url) {
  const match = typeof url === 'string' ? url.match(/\/o\/([^?]+)/) : null;
  if (!match) return null;
  try {
    return decodeURIComponent(match[1]);
  } catch {
    return null;
  }
}

// MARK: - CLI

/** Prints counts, and with `--apply` writes the documents to Firestore (emulator or production). */
async function main(argv) {
  const apply = argv.includes('--apply');
  const file = argv.find((arg) => !arg.startsWith('--'));
  if (!file) {
    console.error('Usage: node scripts/migrate-archive.mjs <rtdb-export.json> [--apply]');
    process.exitCode = 2;
    return;
  }

  const raw = JSON.parse(await readFile(file, 'utf8'));
  const universities = raw[ROOT_KEY] ?? raw;
  const { catalogNodes, exams } = buildFirestoreDocs(universities);
  const fileCount = exams.reduce((sum, exam) => sum + exam.data.files.length, 0);
  console.log(`catalogNodes: ${catalogNodes.length}, exams: ${exams.length}, files: ${fileCount}`);

  if (!apply) {
    console.log('Dry run (no --apply): nothing written.');
    return;
  }

  // Loaded only when actually writing, so the transform and its tests need no Admin SDK installed.
  const { initializeApp, applicationDefault } = await import('firebase-admin/app');
  const { getFirestore } = await import('firebase-admin/firestore');
  const usingEmulator = Boolean(process.env.FIRESTORE_EMULATOR_HOST);
  console.log(usingEmulator
    ? `Writing to EMULATOR ${process.env.FIRESTORE_EMULATOR_HOST}`
    : 'Writing to PRODUCTION Firestore (credentials from GOOGLE_APPLICATION_CREDENTIALS / gcloud ADC)');
  // Require an explicit project in production so a stray credential can never write to the wrong project.
  const projectId = process.env.GCLOUD_PROJECT || process.env.GOOGLE_CLOUD_PROJECT || (usingEmulator ? 'demo-vifi' : undefined);
  if (!projectId) {
    console.error('Set GCLOUD_PROJECT (e.g. GCLOUD_PROJECT=vifi-831a8) for a production run.');
    process.exitCode = 2;
    return;
  }
  // On the emulator the SDK ignores credentials; in production it uses the owner's Application Default Credentials.
  const app = initializeApp(usingEmulator
    ? { projectId }
    : { credential: applicationDefault(), projectId });
  // The archive lives in the named `vifi` database (the `(default)` one is legacy Datastore mode); override
  // with FIRESTORE_DATABASE_ID if needed.
  const databaseId = process.env.FIRESTORE_DATABASE_ID ?? 'vifi';
  console.log(`Target database: '${databaseId}'`);
  const db = getFirestore(app, databaseId);
  await writeAll(db, 'catalogNodes', catalogNodes);
  await writeAll(db, 'exams', exams);

  // Read-back verification: the collections must hold at least what we wrote (set is idempotent on re-runs).
  const [catalogBack, examsBack] = await Promise.all([
    db.collection('catalogNodes').get(),
    db.collection('exams').get(),
  ]);
  console.log(`Read-back: catalogNodes ${catalogBack.size}, exams ${examsBack.size} (expected ${catalogNodes.length} / ${exams.length})`);
  if (catalogBack.size < catalogNodes.length || examsBack.size < exams.length) {
    console.error('Read-back is short of what was written; something went wrong.');
    process.exitCode = 1;
    return;
  }
  console.log('Done.');
}

/** Writes documents by id in batches of 500 (`set` → idempotent across re-runs). */
async function writeAll(db, collection, docs) {
  const BATCH = 500;
  for (let start = 0; start < docs.length; start += BATCH) {
    const batch = db.batch();
    for (const { id, data } of docs.slice(start, start + BATCH)) {
      batch.set(db.collection(collection).doc(id), data);
    }
    await batch.commit();
  }
  console.log(`${collection}: wrote ${docs.length}`);
}

// Run `main` only when executed directly (not when imported by tests). `fileURLToPath` decodes the path so
// spaces / non-ASCII in the directory match `process.argv[1]`.
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  await main(process.argv.slice(2));
}

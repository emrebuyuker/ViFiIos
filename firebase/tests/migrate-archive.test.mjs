// Pure tests for the archive→Firestore transform (scripts/migrate-archive.mjs). No emulator, no Admin SDK:
// the actual write is rehearsed against the emulator at the cutover (item #10). A synthetic archive stands in
// for the real backup (which is never committed and never read here).

import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { buildFirestoreDocs, storagePathFromURL } from '../scripts/migrate-archive.mjs';

const BUCKET = 'vifi-831a8.appspot.com';
const url = (path) => `https://firebasestorage.googleapis.com/v0/b/${BUCKET}/o/${encodeURIComponent(path)}?alt=media&token=secret`;

const archive = {
  'BOZOK ÜNİVERSİTESİ': {
    uniname: 'BOZOK ÜNİVERSİTESİ',
    'Mühendislik Fakültesi': {
      fakname: 'Mühendislik Fakültesi',
      'Bilgisayar Mühendisliği': {
        bolname: 'Bilgisayar Mühendisliği',
        'Mühendislik Matematiği': {
          lessonname: 'Mühendislik Matematiği',
          '2019 Final': {
            imagename: '2019 Final',
            JPG: { '-NfA': { downloadURL: url('imagess/a.jpg') }, '-NfB': { downloadURL: url('imagess/b.jpg') } },
          },
          '2018 Vize': {
            imagename: '2018 Vize',
            JPG: { '-NfC': { downloadURL: url('imagess/c.jpg') } },
            'PDF ': { '-NfD': { downloadURL: url('pdfs/d.pdf') } },
          },
          '2017 Bütünleme': {
            imagename: '2017 Bütünleme',
            PDF: { '-NfE': { downloadURL: url('pdfs/e.pdf') } },
          },
          'Boş Sınav': { imagename: 'Boş Sınav' },
        },
        'Boş Ders': { lessonname: 'Boş Ders' },
      },
    },
  },
  'Boş Üniversite': { uniname: 'Boş Üniversite' },
  poc: 'junk-string',
  Announcements: { anything: 1 },
};

const COURSE_ID = 'bozok-universitesi__muhendislik-fakultesi__bilgisayar-muhendisligi__muhendislik-matematigi';

describe('buildFirestoreDocs', () => {
  const { catalogNodes, exams } = buildFirestoreDocs(archive);
  const node = (id) => catalogNodes.find((n) => n.id === id);
  const exam = (title) => exams.find((e) => e.data.title === title);

  test('emits one catalog node per non-empty level, pruning empty branches and junk', () => {
    assert.deepEqual(
      catalogNodes.map((n) => n.id).sort(),
      [
        'bozok-universitesi',
        'bozok-universitesi__muhendislik-fakultesi',
        'bozok-universitesi__muhendislik-fakultesi__bilgisayar-muhendisligi',
        COURSE_ID,
      ].sort()
    );
    // "Boş Üniversite"/"Boş Ders"/"Boş Sınav" pruned; poc/Announcements skipped.
    assert.equal(node('bos-universite'), undefined);
  });

  test('catalog nodes carry level, display name, parentId chain and child counts', () => {
    assert.deepEqual(node('bozok-universitesi').data, {
      level: 'university', name: 'BOZOK ÜNİVERSİTESİ', parentId: '', status: 'published',
      childCount: 1, slug: 'bozok-universitesi', source: 'migration',
    });
    assert.equal(node('bozok-universitesi__muhendislik-fakultesi').data.parentId, 'bozok-universitesi');
    assert.equal(node('bozok-universitesi__muhendislik-fakultesi__bilgisayar-muhendisligi').data.parentId, 'bozok-universitesi__muhendislik-fakultesi');
    assert.equal(node(COURSE_ID).data.parentId, 'bozok-universitesi__muhendislik-fakultesi__bilgisayar-muhendisligi');
    assert.equal(node(COURSE_ID).data.childCount, 3); // three exams with files
  });

  test('emits an exam per exam-with-files, images winning when both kinds are present', () => {
    assert.equal(exams.length, 3);
    assert.equal(exam('2019 Final').id, `${COURSE_ID}__2019-final`);
    assert.equal(exam('2018 Vize').data.kind, 'JPG'); // JPG beats the trailing-space "PDF " group
    assert.deepEqual(exam('2018 Vize').data.files, [{ storagePath: 'imagess/c.jpg', order: 0 }]);
    assert.equal(exam('2017 Bütünleme').data.kind, 'PDF');
    assert.deepEqual(exam('2017 Bütünleme').data.files, [{ storagePath: 'pdfs/e.pdf', order: 0 }]);
  });

  test('exam files keep upload order and decode the storage path (no token)', () => {
    assert.deepEqual(exam('2019 Final').data.files, [
      { storagePath: 'imagess/a.jpg', order: 0 },
      { storagePath: 'imagess/b.jpg', order: 1 },
    ]);
  });

  test('exam documents denormalise ancestry and reserve the coin/counter fields', () => {
    const data = exam('2019 Final').data;
    assert.equal(data.universityId, 'bozok-universitesi');
    assert.equal(data.courseId, COURSE_ID);
    assert.equal(data.universityName, 'BOZOK ÜNİVERSİTESİ');
    assert.equal(data.courseName, 'Mühendislik Matematiği');
    assert.equal(data.status, 'published');
    assert.equal(data.source, 'migration');
    assert.equal(data.isLocked, false);
    assert.equal(data.coinCost, 0);
    assert.deepEqual(data.counts, { views: 0, downloads: 0, unlocks: 0 });
    assert.equal(data.sortKey, '2019 Final');
  });

  test('the transform is deterministic (idempotent re-runs produce identical ids and data)', () => {
    assert.deepEqual(buildFirestoreDocs(archive), buildFirestoreDocs(archive));
  });
});

describe('storagePathFromURL', () => {
  test('decodes the object path and drops the query/token', () => {
    assert.equal(storagePathFromURL(url('imagess/a b ç.jpg')), 'imagess/a b ç.jpg');
    assert.equal(storagePathFromURL(url('pdfs/x.pdf')), 'pdfs/x.pdf');
  });

  test('returns null for a non-storage URL', () => {
    assert.equal(storagePathFromURL('https://example.com/x'), null);
    assert.equal(storagePathFromURL(42), null);
  });
});

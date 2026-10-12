// Parity test for scripts/slug.mjs — the input→output pairs are identical to ViFiTests/SlugTests.swift.
// If these pass here and there, the migration's archive ids match the app's profile ids / FCM topics.

import { describe, test } from 'node:test';
import assert from 'node:assert/strict';
import { slug } from '../scripts/slug.mjs';

describe('slug — parity with Swift Slug.make', () => {
  const cases = [
    ['Sakarya Üniversitesi', 'sakarya-universitesi'],
    ['Boğaziçi Üniversitesi', 'bogazici-universitesi'],
    ['İstanbul Teknik Üniversitesi', 'istanbul-teknik-universitesi'],
    ['İşletme', 'isletme'],
    ['Mühendislik-Mimarlık Fakültesi', 'muhendislik-mimarlik-fakultesi'],
    ['Fen-Edebiyat Fakültesi', 'fen-edebiyat-fakultesi'],
    ['Çaycuma', 'caycuma'],
  ];
  for (const [input, expected] of cases) {
    test(`"${input}" -> "${expected}"`, () => {
      assert.equal(slug(input), expected);
    });
  }

  test('separators collapse and do not lead or trail', () => {
    assert.equal(slug('  Boş   Köy  '), 'bos-koy');
    assert.equal(slug('A, B & C'), 'a-b-c');
    assert.equal(slug('---x---'), 'x');
  });

  test('a value with no usable characters falls back to a placeholder', () => {
    assert.equal(slug(''), 'unknown');
    assert.equal(slug('   '), 'unknown');
    assert.equal(slug('...'), 'unknown');
  });
});

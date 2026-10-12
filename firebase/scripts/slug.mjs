// Canonical slug generator — an exact port of ViFi/Core/Utilities/Slug.swift.
//
// MUST stay in lockstep with the Swift `Slug.make`: the migration writes archive ids with this, and the app
// derives profile ids / FCM topics with the Swift version, so a divergence would break segmentation and joins.
// The parity is pinned by scripts/../tests/slug.test.mjs, which asserts the same input→output pairs as
// ViFiTests/SlugTests.swift.

// Turkish letters mapped to their ASCII base BEFORE lowercasing (plain lowercasing mishandles İ/I).
const TURKISH_MAP = {
  İ: 'i', I: 'i', ı: 'i',
  Ğ: 'g', ğ: 'g',
  Ü: 'u', ü: 'u',
  Ş: 's', ş: 's',
  Ö: 'o', ö: 'o',
  Ç: 'c', ç: 'c',
};

/** Turns a display name into a stable, topic-safe slug (`[a-z0-9-]`); `"unknown"` when empty. */
export function slug(input) {
  // NFC first: Swift iterates grapheme clusters, so a decomposed accent (base + combining mark) is one
  // non-ASCII Character it drops. Composing to NFC makes the JS code-point scan drop it the same way, keeping
  // parity on real (already-NFC) data and on any decomposed input alike.
  const lowered = [...input.normalize('NFC')].map((ch) => TURKISH_MAP[ch] ?? ch).join('').toLowerCase();

  // Keep ASCII letters/digits; collapse every other run into a single dash, with no leading or trailing dash
  // (the dash is only flushed right before the next kept character).
  let result = '';
  let pendingDash = false;
  for (const ch of lowered) {
    if (ch.charCodeAt(0) < 128 && /[a-z0-9]/.test(ch)) {
      if (pendingDash) {
        result += '-';
        pendingDash = false;
      }
      result += ch;
    } else if (result.length > 0) {
      pendingDash = true;
    }
  }
  return result === '' ? 'unknown' : result;
}

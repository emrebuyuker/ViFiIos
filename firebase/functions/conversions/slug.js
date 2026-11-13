// Canonical slug generator for the Cloud Functions bundle — a copy of `scripts/slug.mjs` (itself a port of
// ViFi/Core/Utilities/Slug.swift). The functions source root is `functions/`, so it cannot import from `scripts/`.
//
// MUST stay identical to `scripts/slug.mjs`: tests/conversionSchema.test.mjs asserts both give the same output for
// the shared Swift parity cases (ViFiTests/SlugTests.swift).

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
  const lowered = [...input.normalize('NFC')].map((ch) => TURKISH_MAP[ch] ?? ch).join('').toLowerCase();
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

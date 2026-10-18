// Look up login-failure diagnostics by phone number.
//
// The number is never stored raw — only a salted hash (sha256(`${salt}:${e164}`), salt trimmed) and the last 4
// digits. This recomputes that exact hash so you can find one user's recent failures (see login-diagnostics
// feature: the recordLoginDiagnostic function writes the records; TTL deletes them after 60 days).
//
// Usage:
//   node scripts/lookup-login-diagnostics.mjs 05321234567
//       Prints the hash, then queries Firestore (needs owner Application Default Credentials:
//       `gcloud auth application-default login`, or GOOGLE_APPLICATION_CREDENTIALS).
//   node scripts/lookup-login-diagnostics.mjs 05321234567 --hash-only
//       Only prints numberHash + last4 — paste numberHash into the Firebase Console:
//       Firestore > loginDiagnostics, filter `numberHash == <value>` (no ADC needed).
//
// The salt comes from $LOGIN_DIAGNOSTIC_SALT if set, otherwise it is read via the firebase CLI
// (`firebase functions:secrets:access LOGIN_DIAGNOSTIC_SALT`); set $FIREBASE_ACCOUNT to pick the owner account.
// The salt value is never printed.

import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const PROJECT = process.env.GCLOUD_PROJECT || 'vifi-831a8';
const DATABASE = process.env.FIRESTORE_DATABASE_ID || 'vifi';

/** Normalises a Turkish mobile number to E.164 (`+90XXXXXXXXXX`), matching what the app sends; throws if invalid. */
export function toE164(input) {
  let national = String(input).replace(/\D/g, '');
  if (national.startsWith('90')) national = national.slice(2);
  if (national.startsWith('0')) national = national.slice(1);
  if (!/^[1-9][0-9]{9}$/.test(national)) {
    throw new Error(`Geçersiz numara: "${input}". 10 haneli cep numarası ver (örn. 5321234567 / 05321234567).`);
  }
  return `+90${national}`;
}

/** The salted hash, byte-for-byte identical to the recordLoginDiagnostic function (salt trimmed, then `${salt}:${e164}`). */
export function numberHash(salt, e164) {
  return createHash('sha256').update(`${salt.trim()}:${e164}`).digest('hex');
}

/** The salt, from the env var or the firebase CLI. Never printed. */
function resolveSalt() {
  if (process.env.LOGIN_DIAGNOSTIC_SALT) return process.env.LOGIN_DIAGNOSTIC_SALT;
  const args = ['functions:secrets:access', 'LOGIN_DIAGNOSTIC_SALT', '--project', PROJECT];
  if (process.env.FIREBASE_ACCOUNT) args.push('--account', process.env.FIREBASE_ACCOUNT);
  try {
    return execFileSync('firebase', args, { encoding: 'utf8' });
  } catch {
    throw new Error(
      'Salt alınamadı. $LOGIN_DIAGNOSTIC_SALT ver, ya da firebase CLI ile owner hesabına giriş yap '
        + '($FIREBASE_ACCOUNT=<owner> ile hesabı seçebilirsin).'
    );
  }
}

async function queryFirestore(hash) {
  const { initializeApp, applicationDefault } = await import('firebase-admin/app');
  const { getFirestore } = await import('firebase-admin/firestore');
  const app = initializeApp({ credential: applicationDefault(), projectId: PROJECT });
  const db = getFirestore(app, DATABASE);
  // Equality-only filter (no composite index needed); sort newest-first in memory.
  const snapshot = await db.collection('loginDiagnostics').where('numberHash', '==', hash).limit(200).get();
  return snapshot.docs
    .map((doc) => doc.data())
    .sort((a, b) => (toMillis(b.createdAt) ?? 0) - (toMillis(a.createdAt) ?? 0));
}

function toMillis(timestamp) {
  return typeof timestamp?.toMillis === 'function' ? timestamp.toMillis() : null;
}

function formatRow(record) {
  const when = record.createdAt?.toDate?.()?.toISOString?.() ?? record.occurredAt ?? '?';
  const code = record.backendCode ? ` (code ${record.backendCode})` : '';
  const appCheck = `appCheck srv=${record.appCheckServer ?? '-'} cli=${record.appCheckClient ?? '-'}`;
  const device = `${record.appVersion ?? '-'} · iOS ${record.osVersion ?? '-'} · ${record.deviceModel ?? '-'}`;
  return `- ${when} | ${record.step ?? '?'} | ${record.reason ?? '?'}${code} | ${appCheck} | ${device}`;
}

async function main(argv) {
  const hashOnly = argv.includes('--hash-only');
  const input = argv.find((arg) => !arg.startsWith('--'));
  if (!input) {
    console.error('Usage: node scripts/lookup-login-diagnostics.mjs <telefon> [--hash-only]');
    process.exitCode = 2;
    return;
  }

  const e164 = toE164(input);
  const hash = numberHash(resolveSalt(), e164);
  console.log(`Numara: ${e164}  ·  last4: ${e164.slice(-4)}`);
  console.log(`numberHash: ${hash}`);

  if (hashOnly) {
    console.log('\nFirebase Console → Firestore (vifi) → loginDiagnostics, filtre: numberHash == yukarıdaki değer.');
    return;
  }

  let records;
  try {
    records = await queryFirestore(hash);
  } catch (error) {
    console.error(`\nFirestore sorgusu başarısız (yetki/ADC olmayabilir): ${error.message}`);
    console.error('Yetki yoksa --hash-only ile hash’i alıp Console’da filtreleyebilirsin.');
    process.exitCode = 1;
    return;
  }

  if (records.length === 0) {
    console.log('\nBu numara için kayıt yok (TTL: son ~60 gün).');
    return;
  }
  console.log(`\n${records.length} kayıt (yeniden eskiye):`);
  for (const record of records) console.log(formatRow(record));
}

// Run only when executed directly (not when imported by tests). `fileURLToPath` decodes spaces/non-ASCII in the path.
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  await main(process.argv.slice(2));
}

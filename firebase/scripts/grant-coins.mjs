// Manually credit (or set) a user's coin balance in Cloud Firestore (the `vifi` database), with a matching
// audit entry in the append-only ledger. This is the out-of-band twin of what FirebaseModerationService does on
// an approval, but with ledger `type: "adjust"` (a manual correction, not an earn). The balance stays
// server-authoritative: the Admin SDK bypasses the security rules, so this never needs an admin client.
//
// The wallet keeps its exact shape (`balance` int >= 0, `updatedAt` timestamp) so the app and future admin-app
// writes stay valid. The phone number is only ever a CLI argument — never store it in this file or a commit.
//
// Usage (run from the `firebase/` directory; needs owner Application Default Credentials:
// `gcloud auth application-default login`, or GOOGLE_APPLICATION_CREDENTIALS):
//   node scripts/grant-coins.mjs <telefon> <miktar>            # miktar kadar EKLER (increment)
//   node scripts/grant-coins.mjs --uid <UID> <miktar>          # UID doğrudan verilir
//   node scripts/grant-coins.mjs <telefon> <miktar> --set      # bakiyeyi tam <miktar> değerine AYARLAR
//   node scripts/grant-coins.mjs <telefon> <miktar> --note "…" # ledger notu
//   node scripts/grant-coins.mjs <telefon> <miktar> --dry-run  # yazmadan önizler (uid + mevcut bakiye)

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

/** Parses argv into { phone?, uid?, amount, set, note, dryRun }; throws on bad input. */
export function parseArgs(argv) {
  const positional = [];
  let uid;
  let note = 'manuel ayarlama';
  let set = false;
  let dryRun = false;
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--uid') { uid = argv[(i += 1)]; } else if (arg === '--note') { note = argv[(i += 1)]; } else if (arg === '--set') { set = true; } else if (arg === '--dry-run') { dryRun = true; } else { positional.push(arg); }
  }
  if (uid === undefined && positional.length < 2) {
    throw new Error('Kullanım: node scripts/grant-coins.mjs <telefon> <miktar> [--set] [--note "…"] [--dry-run]');
  }
  // With --uid the single positional is the amount; otherwise it is <telefon> <miktar>.
  const amountRaw = uid === undefined ? positional[1] : positional[0];
  const phone = uid === undefined ? positional[0] : undefined;
  const amount = Number(amountRaw);
  if (!Number.isInteger(amount) || amount === 0) {
    throw new Error(`Geçersiz miktar: "${amountRaw}". Sıfırdan farklı tam sayı ver (ör. 500, --set ile 0 da olabilir değil).`);
  }
  return { phone, uid, amount, set, note, dryRun };
}

async function main(argv) {
  const { phone, uid: uidArg, amount, set, note, dryRun } = parseArgs(argv);

  const { initializeApp, applicationDefault } = await import('firebase-admin/app');
  const { getFirestore, FieldValue } = await import('firebase-admin/firestore');
  const { getAuth } = await import('firebase-admin/auth');
  const app = initializeApp({ credential: applicationDefault(), projectId: PROJECT });
  const db = getFirestore(app, DATABASE);

  // Resolve the uid: directly, or from the phone number via Auth.
  let uid = uidArg;
  if (!uid) {
    const e164 = toE164(phone);
    const user = await getAuth(app).getUserByPhoneNumber(e164);
    uid = user.uid;
    console.log(`Kullanıcı: ${e164}  ·  uid: ${uid}`);
  } else {
    console.log(`Kullanıcı: uid ${uid}`);
  }

  const walletRef = db.collection('wallets').doc(uid);

  // Preview: read current balance so we can show mevcut → yeni before any write.
  const current = (await walletRef.get()).data()?.balance ?? 0;
  const newBalance = set ? amount : current + amount;
  const delta = newBalance - current;
  if (newBalance < 0) {
    throw new Error(`Bakiye negatif olamaz: mevcut ${current} ${set ? '→ set' : '+'} ${amount} = ${newBalance}.`);
  }
  console.log(`Bakiye: ${current} → ${newBalance}  (${delta >= 0 ? '+' : ''}${delta}, mod: ${set ? 'set' : 'ekle'})`);

  if (dryRun) {
    console.log('\n[dry-run] Yazılmadı.');
    return;
  }
  if (delta === 0) {
    console.log('\nDeğişiklik yok (delta 0) — ledger’a bir şey yazılmadı.');
    return;
  }

  // Race-safe write: re-read inside the transaction, write the wallet, append one immutable ledger entry.
  await db.runTransaction(async (tx) => {
    const snapshot = await tx.get(walletRef);
    const live = snapshot.data()?.balance ?? 0;
    const finalBalance = set ? amount : live + amount;
    if (finalBalance < 0) throw new Error(`Bakiye negatif olamaz (canlı okuma): ${live} → ${finalBalance}.`);
    const finalDelta = finalBalance - live;
    tx.set(walletRef, { balance: finalBalance, updatedAt: FieldValue.serverTimestamp() }, { merge: true });
    if (finalDelta !== 0) {
      tx.set(walletRef.collection('ledger').doc(), {
        type: 'adjust',
        amount: finalDelta,
        balanceAfter: finalBalance,
        note,
        createdAt: FieldValue.serverTimestamp(),
      });
    }
  });

  const confirmed = (await walletRef.get()).data()?.balance ?? 0;
  console.log(`\nYazıldı. Yeni bakiye: ${confirmed}  ·  ledger: adjust (not: "${note}").`);
}

// Run only when executed directly (not when imported by tests). `fileURLToPath` decodes spaces/non-ASCII in the path.
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  try {
    await main(process.argv.slice(2));
  } catch (error) {
    console.error(`Hata: ${error.message}`);
    process.exitCode = 1;
  }
}

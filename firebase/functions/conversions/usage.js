// AI cost accounting and the monthly spend cap (owner decision K11): `aiUsage/{YYYY-MM}` (Europe/Istanbul month,
// `usageMonthKey`) sums what every conversion run cost. Once a month's regular spend reaches `MONTHLY_CAP_USD`, new
// runs stay `queued` until the next month and the admins get one notice per month. One-time migration-script jobs
// (`budget: 'oneTime'`, K12c) never wait on the cap; they are summed separately under `oneTime`.
//
// `aiUsage/{month}` (server only; admins read) =
//   { month, costUsd, inputTokens, outputTokens, runs,                       — regular (capped) spend
//     oneTime: { costUsd, inputTokens, outputTokens, runs },                 — script spend, not capped
//     byProvider: { claude|gemini: { costUsd, inputTokens, outputTokens, runs } }, — both budgets together
//     capNotifiedAt?, updatedAt }
//
// Costs are the provider list prices in `providers/config.js` (see the batch-discount note there).

import { FieldValue } from 'firebase-admin/firestore';
import { usageMonthKey } from './schema.js';
import { ESTIMATED_TOKENS_PER_PAGE, PROVIDER_CONFIG } from './providers/config.js';

export const MONTHLY_CAP_USD = 50;
export const USAGE_COLLECTION = 'aiUsage';
export const BUDGETS = Object.freeze(['monthly', 'oneTime']);

const ISTANBUL_OFFSET_MS = 3 * 60 * 60 * 1000;

/** The job's budget: only an explicit `oneTime` escapes the cap. */
export const jobBudget = (job) => (job?.budget === 'oneTime' ? 'oneTime' : 'monthly');

/** USD for one run's token counts at the provider's list price (tiered by prompt size where the provider is). */
export function costUsd(provider, { inputTokens = 0, outputTokens = 0 } = {}) {
  const config = PROVIDER_CONFIG[provider];
  if (!config) throw new Error(`Unknown provider ${provider}`);
  const tier = config.pricing.tiers.find((entry) => entry.upToInputTokens === undefined || inputTokens <= entry.upToInputTokens);
  const usd = (inputTokens * tier.inputPerMTok + outputTokens * tier.outputPerMTok) / 1_000_000;
  return Math.round(usd * 1_000_000) / 1_000_000;
}

/** A pre-run estimate from the page count (budget check; the bulk dry-run in Faz 1B can reuse it). */
export function estimateJobCostUsd({ provider, pageCount }) {
  const pages = Math.max(1, Number.isInteger(pageCount) ? pageCount : 1);
  return costUsd(provider, {
    inputTokens: pages * ESTIMATED_TOKENS_PER_PAGE.input,
    outputTokens: pages * ESTIMATED_TOKENS_PER_PAGE.output,
  });
}

/**
 * True when starting a run would break the cap: what the month already spent plus this run's estimate exceeds it.
 * Runs that start together can still overshoot by at most (queue concurrency × one run's cost) — accepted.
 */
export function isOverCap({ spentUsd, estimateUsd, capUsd = MONTHLY_CAP_USD }) {
  return (Number(spentUsd) || 0) + (Number(estimateUsd) || 0) > capUsd;
}

/** 00:00 Europe/Istanbul on the first day of the month after `date`. */
export function nextMonthStart(date) {
  const shifted = new Date(date.getTime() + ISTANBUL_OFFSET_MS);
  return new Date(Date.UTC(shifted.getUTCFullYear(), shifted.getUTCMonth() + 1, 1) - ISTANBUL_OFFSET_MS);
}

export const usageRef = (db, month) => db.collection(USAGE_COLLECTION).doc(month);

/** The regular (capped) spend of a usage snapshot. */
export const spentUsd = (snapshot) => (snapshot.exists ? Number(snapshot.get('costUsd')) || 0 : 0);

/**
 * Adds one run's usage to the month (to `oneTime` for script jobs) and the per-provider totals. Called right after
 * the model answered, before validation, so a run that is later rejected still counts — the money was spent.
 */
export function addUsage(writer, db, { month, provider, budget, usage, cost, now }) {
  const totals = {
    costUsd: FieldValue.increment(cost),
    inputTokens: FieldValue.increment(usage.inputTokens),
    outputTokens: FieldValue.increment(usage.outputTokens),
    runs: FieldValue.increment(1),
  };
  writer.set(usageRef(db, month), {
    month,
    ...(budget === 'oneTime' ? { oneTime: totals } : totals),
    byProvider: { [provider]: totals },
    updatedAt: now,
  }, { merge: true });
}

/** Claims the month's single "cap reached" notice: true for the first caller only. */
export async function claimCapNotice(db, month, now) {
  return db.runTransaction(async (tx) => {
    const ref = usageRef(db, month);
    const snapshot = await tx.get(ref);
    if (snapshot.exists && snapshot.get('capNotifiedAt')) return false;
    tx.set(ref, { month, capNotifiedAt: now, updatedAt: now }, { merge: true });
    return true;
  });
}

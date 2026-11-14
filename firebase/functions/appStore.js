// App Store transaction verification for the paid single-exam unlock and the practice mode's Premium proof.
//
// A client that buys the `exam.unlock` consumable sends the transaction's signed representation (StoreKit 2
// JWS). We verify Apple's signature here — never trust the client — so an exam is unlocked only for a real,
// paid transaction. Uses Apple's official `@apple/app-store-server-library`.
//
// Note: transactions created by a local Xcode StoreKit configuration file are signed in the `Xcode` /
// `LocalTesting` environment, NOT by Apple's production root, so they do not verify here. The paid flow is
// therefore end-to-end testable only against real Sandbox (a device with a sandbox Apple ID) or Production.

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { Environment, SignedDataVerifier } from '@apple/app-store-server-library';

const here = dirname(fileURLToPath(import.meta.url));

/** The app's bundle id; a transaction for any other app is rejected. */
export const BUNDLE_ID = 'com.BuyukerYazilim.ViFi2';

/** The consumable product that unlocks a single exam. */
export const EXAM_UNLOCK_PRODUCT_ID = 'com.BuyukerYazilim.ViFi2.exam.unlock';

/** The Premium auto-renewable subscriptions (`StoreProductID.subscriptions` in the app). */
export const SUBSCRIPTION_PRODUCT_IDS = Object.freeze([
  'com.BuyukerYazilim.ViFi2.premium.monthly',
  'com.BuyukerYazilim.ViFi2.premium.yearly',
]);

// The app's numeric App Store id, required to verify PRODUCTION transactions. Unknown until the app is
// published; set APP_APPLE_ID in the function's environment then. Until it is set, only Sandbox transactions
// are verifiable (which is all that exists pre-launch).
const APP_APPLE_ID = Number(process.env.APP_APPLE_ID) || undefined;

// Apple's root CA that anchors the transaction's signing chain. Committed alongside the function (a public
// certificate, not a secret).
const appleRootCAs = [readFileSync(join(here, 'certs', 'AppleRootCA-G3.cer'))];

// One verifier per environment, built lazily and reused.
const verifiers = new Map();

function verifierFor(environment) {
  if (!verifiers.has(environment)) {
    verifiers.set(
      environment,
      new SignedDataVerifier(appleRootCAs, /* enableOnlineChecks */ false, environment, BUNDLE_ID, APP_APPLE_ID)
    );
  }
  return verifiers.get(environment);
}

// Production is tried only once the app's numeric id is configured; Sandbox is always tried (and is the only
// environment that exists before launch).
function environmentsToTry() {
  const environments = [];
  if (APP_APPLE_ID) environments.push(Environment.PRODUCTION);
  environments.push(Environment.SANDBOX);
  return environments;
}

/**
 * Verifies a StoreKit 2 signed transaction's signature (Apple's chain, this app's bundle id) in every environment the
 * server can verify, and returns the decoded payload. Product checks are the caller's.
 *
 * @param {string} signedTransaction The JWS representation from `Transaction.jwsRepresentation`.
 * @returns {Promise<object>} The decoded `JWSTransactionDecodedPayload`.
 */
export async function verifySignedTransaction(signedTransaction) {
  if (typeof signedTransaction !== 'string' || signedTransaction.length === 0) {
    throw new Error('empty signed transaction');
  }

  let lastError;
  for (const environment of environmentsToTry()) {
    try {
      const payload = await verifierFor(environment).verifyAndDecodeTransaction(signedTransaction);
      if (payload.bundleId !== BUNDLE_ID) {
        throw new Error(`unexpected bundle id ${payload.bundleId}`);
      }
      return payload;
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError ?? new Error('verification failed');
}

/**
 * Verifies a StoreKit 2 signed transaction and returns its decoded payload, or throws if the signature,
 * environment, bundle id or product id is wrong. The caller still applies replay protection.
 *
 * @param {string} signedTransaction The JWS representation from `Transaction.jwsRepresentation`.
 * @returns {Promise<{transactionId: string, productId: string, bundleId: string}>}
 */
export async function verifyExamUnlockTransaction(signedTransaction) {
  const payload = await verifySignedTransaction(signedTransaction);
  if (payload.productId !== EXAM_UNLOCK_PRODUCT_ID) {
    throw new Error(`unexpected product id ${payload.productId}`);
  }
  if (!payload.transactionId) {
    throw new Error('transaction has no id');
  }
  return payload;
}

/**
 * Verifies the signed transaction of the current Premium entitlement (practice mode's `subscriptionProof`, contract:
 * conversions/schema.js PRACTICE MODE) and returns its decoded payload; throws for a bad signature, another app or a
 * product that is not a subscription. Expiry and revocation are checked by the caller against its own clock
 * (`subscriptionFromTransaction`, conversions/practice.js).
 *
 * @param {string} signedTransaction
 * @returns {Promise<{productId: string, originalTransactionId: string, expiresDate?: number, revocationDate?: number}>}
 */
export async function verifySubscriptionTransaction(signedTransaction) {
  const payload = await verifySignedTransaction(signedTransaction);
  if (!SUBSCRIPTION_PRODUCT_IDS.includes(payload.productId)) {
    throw new Error(`unexpected product id ${payload.productId}`);
  }
  return payload;
}

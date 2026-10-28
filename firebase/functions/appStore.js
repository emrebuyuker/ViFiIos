// App Store transaction verification for the paid single-exam unlock.
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
 * Verifies a StoreKit 2 signed transaction and returns its decoded payload, or throws if the signature,
 * environment, bundle id or product id is wrong. The caller still applies replay protection.
 *
 * @param {string} signedTransaction The JWS representation from `Transaction.jwsRepresentation`.
 * @returns {Promise<{transactionId: string, productId: string, bundleId: string}>}
 */
export async function verifyExamUnlockTransaction(signedTransaction) {
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
      if (payload.productId !== EXAM_UNLOCK_PRODUCT_ID) {
        throw new Error(`unexpected product id ${payload.productId}`);
      }
      if (!payload.transactionId) {
        throw new Error('transaction has no id');
      }
      return payload;
    } catch (error) {
      lastError = error;
    }
  }
  throw lastError ?? new Error('verification failed');
}

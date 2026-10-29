// Google Play purchase verification for the paid single-exam unlock (Android, 4.0.0).
//
// The Android client buys the `exam_unlock` one-time product with `obfuscatedProfileId = examId`, then sends the
// purchase token here. We look the purchase up with the Google Play Developer API — never trust the client — and
// accept it only when it is paid, for this app's product, and bought for the exam being unlocked. The caller still
// applies replay protection with the returned transaction id. The server never consumes the purchase: the client
// consumes it only after the unlock is recorded, so a failed call never loses a paid unlock.
//
// Access: the Google Play Android Developer API must be enabled on the project, and the function's runtime service
// account must be invited in Play Console with permission to view financial data. Until then (or while a new grant
// propagates, which can take hours) the API answers 401/403 and verification fails as `misconfigured`.

import { createHash } from 'node:crypto';
import { GoogleAuth } from 'google-auth-library';

/** The Android app's package name; a purchase of any other app is rejected. */
export const PACKAGE_NAME = 'com.salticusteam.vifi';

/** The one-time (consumable) product that unlocks a single exam. */
export const EXAM_UNLOCK_PRODUCT_ID = 'exam_unlock';

// `purchases.products` purchaseState: 0 = purchased, 1 = canceled, 2 = pending.
const PURCHASE_STATE_PURCHASED = 0;

// Play caps `obfuscatedProfileId` at 64 characters, so a longer exam id can never match a purchase.
const MAX_EXAM_ID_LENGTH = 64;

// Purchase tokens are opaque; the cap only keeps an abusive input out of the API URL.
const MAX_PURCHASE_TOKEN_LENGTH = 4096;

// Order ids look like "GPA.1234-5678-9012-34567" and are safe Firestore document ids as they are.
const ORDER_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;

const ANDROID_PUBLISHER_SCOPE = 'https://www.googleapis.com/auth/androidpublisher';
const API_BASE_URL = 'https://androidpublisher.googleapis.com/androidpublisher/v3';
const REQUEST_TIMEOUT_MS = 10_000;

/**
 * Why a purchase could not be verified:
 * - `rejected`: the purchase is not a valid, paid `exam_unlock` for this exam (the client must not retry it).
 * - `unavailable`: Google Play could not be reached or is overloaded (a later retry may succeed).
 * - `misconfigured`: the server has no access to the Play Developer API (an operations problem, not the user's).
 */
export class PlayVerificationError extends Error {
  constructor(reason, message, options) {
    super(message, options);
    this.name = 'PlayVerificationError';
    this.reason = reason;
  }
}

const rejected = (message) => new PlayVerificationError('rejected', message);

/**
 * Maps a failed Play Developer API call to a verification error. An HTTP 4xx means the token is unknown, malformed
 * or expired for this product; 401/403 mean the server lacks access; 429, 5xx and a missing response are transient.
 *
 * @param {unknown} error The error thrown by the HTTP client (`GaxiosError` carries `response.status`).
 * @returns {PlayVerificationError}
 */
export function classifyPlayApiError(error) {
  if (error instanceof PlayVerificationError) return error;
  const status = error?.response?.status;
  if (status === 401 || status === 403) {
    return new PlayVerificationError('misconfigured', `Play Developer API refused access (${status})`, { cause: error });
  }
  if (typeof status === 'number' && status >= 400 && status < 500 && status !== 408 && status !== 429) {
    return new PlayVerificationError('rejected', `Play Developer API rejected the purchase (${status})`, { cause: error });
  }
  return new PlayVerificationError('unavailable', `Play Developer API unavailable (${status ?? 'no response'})`, {
    cause: error,
  });
}

/**
 * The replay key of a purchase: its order id, or — when there is none (some test and promo purchases) or it is not
 * a safe document id — a hash of the purchase token. Either is stable for the same purchase.
 *
 * @param {{orderId?: string}} purchase The Play `ProductPurchase` resource.
 * @param {string} purchaseToken The token the purchase was looked up with.
 * @returns {string}
 */
export function transactionIdFor(purchase, purchaseToken) {
  const orderId = typeof purchase?.orderId === 'string' ? purchase.orderId.trim() : '';
  if (ORDER_ID_PATTERN.test(orderId)) return orderId;
  return `play-token-${createHash('sha256').update(purchaseToken).digest('hex')}`;
}

// One auth client per instance, built lazily and reused across invocations.
let googleAuth;

/**
 * Looks a one-time product purchase up with the Play Developer API (`purchases.products.get`).
 *
 * @returns {Promise<object>} The `ProductPurchase` resource.
 */
export async function fetchProductPurchase({ packageName, productId, purchaseToken }) {
  let client;
  try {
    googleAuth ??= new GoogleAuth({ scopes: [ANDROID_PUBLISHER_SCOPE] });
    client = await googleAuth.getClient();
  } catch (error) {
    throw new PlayVerificationError('misconfigured', 'No credentials for the Play Developer API', { cause: error });
  }
  const url =
    `${API_BASE_URL}/applications/${encodeURIComponent(packageName)}` +
    `/purchases/products/${encodeURIComponent(productId)}/tokens/${encodeURIComponent(purchaseToken)}`;
  const response = await client.request({
    url,
    method: 'GET',
    timeout: REQUEST_TIMEOUT_MS,
    retryConfig: { retry: 2 },
  });
  return response.data;
}

/**
 * Verifies an `exam_unlock` purchase with Google Play and returns its replay key, or throws a
 * {@link PlayVerificationError} if the purchase is not paid, is for another product, or was bought for another exam.
 * Inputs are checked before Google Play is called, so a malformed request never reaches the API.
 *
 * @param {{purchaseToken: unknown, productId: unknown, examId: string}} input What the client sent.
 * @param {typeof fetchProductPurchase} [fetchPurchase] The Play lookup; replaced in tests.
 * @returns {Promise<{transactionId: string}>}
 */
export async function verifyExamUnlockPurchase({ purchaseToken, productId, examId }, fetchPurchase = fetchProductPurchase) {
  if (typeof purchaseToken !== 'string' || !purchaseToken || purchaseToken.length > MAX_PURCHASE_TOKEN_LENGTH) {
    throw rejected('invalid purchase token');
  }
  if (productId !== EXAM_UNLOCK_PRODUCT_ID) {
    throw rejected(`unexpected product id ${productId}`);
  }
  if (typeof examId !== 'string' || !examId || examId.length > MAX_EXAM_ID_LENGTH) {
    throw rejected('invalid exam id');
  }

  let purchase;
  try {
    purchase = await fetchPurchase({ packageName: PACKAGE_NAME, productId: EXAM_UNLOCK_PRODUCT_ID, purchaseToken });
  } catch (error) {
    throw classifyPlayApiError(error);
  }

  if (!purchase || typeof purchase !== 'object') {
    throw rejected('empty purchase');
  }
  if (purchase.purchaseState !== PURCHASE_STATE_PURCHASED) {
    throw rejected(`purchase is not paid (state ${purchase.purchaseState})`);
  }
  // The product is fixed by the request URL; the resource may omit it, but must not name another one.
  if (purchase.productId != null && purchase.productId !== EXAM_UNLOCK_PRODUCT_ID) {
    throw rejected(`unexpected purchased product ${purchase.productId}`);
  }
  if (purchase.obfuscatedExternalProfileId !== examId) {
    throw rejected('purchase was bought for another exam');
  }
  return { transactionId: transactionIdFor(purchase, purchaseToken) };
}

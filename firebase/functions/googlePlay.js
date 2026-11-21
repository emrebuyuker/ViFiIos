// Google Play purchase verification for the paid single-exam unlock (Android, 4.0.0).
//
// The Android client buys the `exam_unlock` one-time product with `obfuscatedProfileId` = the SHA-256 of the exam id
// (see examBindingFor), then sends the purchase token here. We look the purchase up with the Google Play Developer
// API — never trust the client — and accept it only when it is paid, for this app's product, and bought for the exam
// being unlocked. The caller still applies replay protection with the returned transaction id. The server never
// consumes the purchase: the client consumes it only after the unlock is recorded, so a failed call never loses a
// paid unlock.
//
// Access: the Google Play Android Developer API must be enabled on the project, and the function's runtime service
// account must be invited in Play Console with permission to view financial data. Until then (or while a new grant
// propagates, which can take hours) the API answers 401/403 and verification fails as `misconfigured`.
//
// Since 4.2.0 it also verifies the ViFi Premium subscription (`vifi_premium`) for the practice mode's Premium proof
// (`verifyPremiumSubscription`, `purchases.subscriptionsv2.get`); the same access covers it.

import { createHash } from 'node:crypto';
import { GoogleAuth } from 'google-auth-library';

/** The Android app's package name; a purchase of any other app is rejected. */
export const PACKAGE_NAME = 'com.salticusteam.vifi';

/** The one-time (consumable) product that unlocks a single exam. */
export const EXAM_UNLOCK_PRODUCT_ID = 'exam_unlock';

// `purchases.products` purchaseState: 0 = purchased, 1 = canceled, 2 = pending.
const PURCHASE_STATE_PURCHASED = 0;

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
 * How a purchase names its exam to Google Play: the SHA-256 hex digest of the exam id. Exam ids are catalog paths far
 * longer than Play's 64-character `obfuscatedProfileId` limit; the digest is exactly 64 characters for any of them.
 * The Android client computes the same digest (`PlayBillingExamPurchaseService.examBinding`).
 *
 * @param {string} examId
 * @returns {string}
 */
export function examBindingFor(examId) {
  return createHash('sha256').update(examId).digest('hex');
}

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

/** The authorized Play Developer API client, or a `misconfigured` error when the runtime has no credentials. */
async function playApiClient() {
  try {
    googleAuth ??= new GoogleAuth({ scopes: [ANDROID_PUBLISHER_SCOPE] });
    return await googleAuth.getClient();
  } catch (error) {
    throw new PlayVerificationError('misconfigured', 'No credentials for the Play Developer API', { cause: error });
  }
}

/**
 * Looks a one-time product purchase up with the Play Developer API (`purchases.products.get`).
 *
 * @returns {Promise<object>} The `ProductPurchase` resource.
 */
export async function fetchProductPurchase({ packageName, productId, purchaseToken }) {
  const client = await playApiClient();
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
  if (typeof examId !== 'string' || !examId) {
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
  if (purchase.obfuscatedExternalProfileId !== examBindingFor(examId)) {
    throw rejected('purchase was bought for another exam');
  }
  return { transactionId: transactionIdFor(purchase, purchaseToken) };
}

// --- ViFi Premium subscription (practice mode's Premium proof, 4.2.0) ----------------------------------------------

/** The Premium subscription product (base plans `monthly` / `yearly`; `StoreProductIds.PREMIUM` in the app). */
export const PREMIUM_SUBSCRIPTION_PRODUCT_ID = 'vifi_premium';

/**
 * `SubscriptionPurchaseV2.subscriptionState` values that still grant Premium, as long as the line item's `expiryTime` is
 * after now (the caller checks it against its own clock, like the App Store `expiresDate`):
 * - ACTIVE: paid and renewing.
 * - IN_GRACE_PERIOD: a renewal payment failed but Google keeps the entitlement (`expiryTime` covers the grace period);
 *   the app's `queryPurchases` still reports it as purchased.
 * - CANCELED: auto-renew turned off; entitled until `expiryTime` (as an App Store subscription that will not renew).
 * Everything else — PENDING, ON_HOLD (account hold), PAUSED, EXPIRED (also refunded / revoked), PENDING_PURCHASE_CANCELED,
 * UNSPECIFIED — is not Premium.
 */
export const ENTITLED_SUBSCRIPTION_STATES = Object.freeze([
  'SUBSCRIPTION_STATE_ACTIVE',
  'SUBSCRIPTION_STATE_IN_GRACE_PERIOD',
  'SUBSCRIPTION_STATE_CANCELED',
]);

// A renewal's order id is the first order's id plus `..<n>` ("GPA.1234-5678-9012-34567..3").
const RENEWAL_SUFFIX_PATTERN = /\.\.\d+$/;

/**
 * How a purchase names its account to Google Play: `obfuscatedAccountId` = the SHA-256 hex digest of the Firebase uid
 * (the Android client's `PlayBillingExamPurchaseService.obfuscatedAccountId`).
 *
 * @param {string} uid
 * @returns {string}
 */
export function accountBindingFor(uid) {
  return createHash('sha256').update(uid).digest('hex');
}

/**
 * The stable id of a subscription across renewals: the base order id (renewal suffix `..<n>` removed), or — when the
 * purchase has no usable order id — a hash of the purchase token (which also stays the same across renewals).
 *
 * @param {string|undefined} orderId The latest order id (`lineItems[].latestSuccessfulOrderId` / `latestOrderId`).
 * @param {string} purchaseToken
 * @returns {string}
 */
export function subscriptionIdFor(orderId, purchaseToken) {
  const base = typeof orderId === 'string' ? orderId.trim().replace(RENEWAL_SUFFIX_PATTERN, '') : '';
  return transactionIdFor({ orderId: base }, purchaseToken);
}

/**
 * Looks a subscription purchase up with the Play Developer API (`purchases.subscriptionsv2.get`).
 *
 * @returns {Promise<object>} The `SubscriptionPurchaseV2` resource.
 */
export async function fetchSubscriptionPurchaseV2({ packageName, purchaseToken }) {
  const client = await playApiClient();
  const url =
    `${API_BASE_URL}/applications/${encodeURIComponent(packageName)}` +
    `/purchases/subscriptionsv2/tokens/${encodeURIComponent(purchaseToken)}`;
  const response = await client.request({
    url,
    method: 'GET',
    timeout: REQUEST_TIMEOUT_MS,
    retryConfig: { retry: 2 },
  });
  return response.data;
}

/**
 * Verifies the practice mode's Android Premium proof (`{ platform: 'android', purchaseToken, productId }`, contract:
 * conversions/schema.js PRACTICE MODE) with Google Play and returns it in the shape the App Store verifier's payload
 * has, so `subscriptionFromTransaction` (conversions/practice.js) treats both platforms alike:
 * `{ productId, originalTransactionId, expiresDate }` — `originalTransactionId` is the base order id
 * (`subscriptionIdFor`), the key of the one-account binding (`subscriptionOwners/android-<id>`); `expiresDate` is the
 * line item's `expiryTime` in epoch ms. Expiry against now is the caller's check.
 *
 * Throws a {@link PlayVerificationError} — which the caller treats as "not Premium", never as a failure — when the input
 * is malformed (checked before Google Play is called), Google Play does not know the token or cannot be reached, the
 * subscription is not in an entitled state, has no `vifi_premium` line item with an expiry, or was bought by another
 * account (`obfuscatedExternalAccountId` set and not the SHA-256 of `uid`; purchases made before the client set it carry
 * none, and the `subscriptionOwners` binding still applies to them).
 *
 * @param {{purchaseToken: unknown, productId: unknown, uid: unknown}} input
 * @param {typeof fetchSubscriptionPurchaseV2} [fetchSubscription] The Play lookup; replaced in tests.
 * @returns {Promise<{productId: string, originalTransactionId: string, expiresDate: number}>}
 */
export async function verifyPremiumSubscription({ purchaseToken, productId, uid }, fetchSubscription = fetchSubscriptionPurchaseV2) {
  if (typeof purchaseToken !== 'string' || !purchaseToken || purchaseToken.length > MAX_PURCHASE_TOKEN_LENGTH) {
    throw rejected('invalid purchase token');
  }
  if (productId !== PREMIUM_SUBSCRIPTION_PRODUCT_ID) {
    throw rejected(`unexpected product id ${productId}`);
  }
  if (typeof uid !== 'string' || !uid) {
    throw rejected('no account to bind the subscription to');
  }

  let purchase;
  try {
    purchase = await fetchSubscription({ packageName: PACKAGE_NAME, purchaseToken });
  } catch (error) {
    throw classifyPlayApiError(error);
  }

  if (!purchase || typeof purchase !== 'object') {
    throw rejected('empty subscription purchase');
  }
  if (!ENTITLED_SUBSCRIPTION_STATES.includes(purchase.subscriptionState)) {
    throw rejected(`subscription is not entitled (state ${purchase.subscriptionState})`);
  }
  const lineItem = Array.isArray(purchase.lineItems)
    ? purchase.lineItems.find((item) => item?.productId === PREMIUM_SUBSCRIPTION_PRODUCT_ID)
    : undefined;
  if (!lineItem) {
    throw rejected('subscription has no Premium line item');
  }
  const expiresDate = typeof lineItem.expiryTime === 'string' ? Date.parse(lineItem.expiryTime) : NaN;
  if (!Number.isFinite(expiresDate)) {
    throw rejected('subscription has no expiry time');
  }
  const boundAccount = purchase.externalAccountIdentifiers?.obfuscatedExternalAccountId;
  if (typeof boundAccount === 'string' && boundAccount !== '' && boundAccount !== accountBindingFor(uid)) {
    throw rejected('subscription was bought by another account');
  }
  return {
    productId: PREMIUM_SUBSCRIPTION_PRODUCT_ID,
    originalTransactionId: subscriptionIdFor(lineItem.latestSuccessfulOrderId ?? purchase.latestOrderId, purchaseToken),
    expiresDate,
  };
}

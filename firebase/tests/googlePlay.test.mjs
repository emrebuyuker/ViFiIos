// Google Play purchase verifier (`functions/googlePlay.js`). The Play Developer API is replaced by a fake lookup, so
// these cover every accept/reject decision without network: input guards (checked before Google Play is called),
// purchase state, product, the exam the purchase was bought for, the replay key, and how API failures are classified —
// and, since 4.2.0, the Premium subscription proof (`verifyPremiumSubscription`): subscription state, product line
// item (the latest expiry wins), expiry, the ignored account id and the renewal-stable subscription id.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import {
  ENTITLED_SUBSCRIPTION_STATES,
  EXAM_UNLOCK_PRODUCT_ID,
  PACKAGE_NAME,
  PREMIUM_SUBSCRIPTION_PRODUCT_ID,
  PlayVerificationError,
  classifyPlayApiError,
  examBindingFor,
  subscriptionIdFor,
  transactionIdFor,
  verifyExamUnlockPurchase,
  verifyPremiumSubscription,
} from '../functions/googlePlay.js';

const TOKEN = 'opaque-purchase-token.AO-J1Oz';
// A real catalog-path exam id: far longer than Play's 64-character obfuscatedProfileId limit.
const EXAM_ID = 'sakarya-universitesi__muhendislik-fakultesi__insaat-muhendisligi__betonarme-1__2009-yaz-okulu-vize';
const sha256 = (value) => createHash('sha256').update(value).digest('hex');
const ORDER_ID = 'GPA.3372-1234-5678-12345';

/** A paid `exam_unlock` bought for EXAM_ID, as `purchases.products.get` returns it. */
function paidPurchase(overrides = {}) {
  return {
    kind: 'androidpublisher#productPurchase',
    purchaseState: 0,
    consumptionState: 0,
    orderId: ORDER_ID,
    productId: EXAM_UNLOCK_PRODUCT_ID,
    obfuscatedExternalProfileId: sha256(EXAM_ID),
    obfuscatedExternalAccountId: 'a'.repeat(64),
    ...overrides,
  };
}

/** A fake Play lookup that records its calls and answers with `result` (or throws it when it is an Error). */
function fakeLookup(result) {
  const calls = [];
  const lookup = async (args) => {
    calls.push(args);
    if (result instanceof Error) throw result;
    return result;
  };
  return { lookup, calls };
}

const request = (overrides = {}) => ({ purchaseToken: TOKEN, productId: EXAM_UNLOCK_PRODUCT_ID, examId: EXAM_ID, ...overrides });

async function assertRejected(promise, reason = 'rejected') {
  await assert.rejects(promise, (error) => {
    assert.ok(error instanceof PlayVerificationError, `expected PlayVerificationError, got ${error}`);
    assert.equal(error.reason, reason);
    return true;
  });
}

test('exposes the Android app identifiers', () => {
  assert.equal(PACKAGE_NAME, 'com.salticusteam.vifi');
  assert.equal(EXAM_UNLOCK_PRODUCT_ID, 'exam_unlock');
});

test('accepts a paid purchase bought for the exam and keys it by order id', async () => {
  const { lookup, calls } = fakeLookup(paidPurchase());

  const result = await verifyExamUnlockPurchase(request(), lookup);

  assert.deepEqual(result, { transactionId: ORDER_ID });
  assert.deepEqual(calls, [{ packageName: PACKAGE_NAME, productId: EXAM_UNLOCK_PRODUCT_ID, purchaseToken: TOKEN }]);
});

test('accepts a paid purchase whose resource omits the product id', async () => {
  const { lookup } = fakeLookup(paidPurchase({ productId: undefined }));
  assert.deepEqual(await verifyExamUnlockPurchase(request(), lookup), { transactionId: ORDER_ID });
});

test('rejects a missing, non-string or oversized token without calling Google Play', async () => {
  for (const purchaseToken of ['', null, undefined, 42, 'x'.repeat(4097)]) {
    const { lookup, calls } = fakeLookup(paidPurchase());
    await assertRejected(verifyExamUnlockPurchase(request({ purchaseToken }), lookup));
    assert.equal(calls.length, 0);
  }
});

test('rejects another product without calling Google Play', async () => {
  for (const productId of ['vifi_premium', 'com.BuyukerYazilim.ViFi2.exam.unlock', '', undefined, null]) {
    const { lookup, calls } = fakeLookup(paidPurchase());
    await assertRejected(verifyExamUnlockPurchase(request({ productId }), lookup));
    assert.equal(calls.length, 0);
  }
});

test('rejects a missing exam id without calling Google Play', async () => {
  for (const examId of ['', undefined, null, 7]) {
    const { lookup, calls } = fakeLookup(paidPurchase());
    await assertRejected(verifyExamUnlockPurchase(request({ examId }), lookup));
    assert.equal(calls.length, 0);
  }
});

test('binds an exam id of any length through its 64-character SHA-256 digest', async () => {
  assert.ok(EXAM_ID.length > 64);
  assert.equal(examBindingFor(EXAM_ID), sha256(EXAM_ID));
  assert.equal(examBindingFor(EXAM_ID).length, 64);
  // The digest of "abc", as the Android client computes it (PlayBillingExamPurchaseServiceTest).
  assert.equal(examBindingFor('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
});

test('rejects a canceled, pending or stateless purchase', async () => {
  for (const purchaseState of [1, 2, undefined, null, '0']) {
    const { lookup } = fakeLookup(paidPurchase({ purchaseState }));
    await assertRejected(verifyExamUnlockPurchase(request(), lookup));
  }
});

test('rejects a purchase resource that names another product', async () => {
  const { lookup } = fakeLookup(paidPurchase({ productId: 'vifi_premium' }));
  await assertRejected(verifyExamUnlockPurchase(request(), lookup));
});

test('rejects a purchase bought for another exam, for no exam, or bound by the raw exam id', async () => {
  const wrongBindings = [sha256('another-exam'), '', undefined, EXAM_ID, sha256(EXAM_ID).toUpperCase()];
  for (const obfuscatedExternalProfileId of wrongBindings) {
    const { lookup } = fakeLookup(paidPurchase({ obfuscatedExternalProfileId }));
    await assertRejected(verifyExamUnlockPurchase(request(), lookup));
  }
});

test('rejects an empty purchase resource', async () => {
  for (const resource of [null, undefined, 'purchase']) {
    const { lookup } = fakeLookup(resource);
    await assertRejected(verifyExamUnlockPurchase(request(), lookup));
  }
});

test('falls back to a stable hash of the token when there is no usable order id', async () => {
  const tokenKey = `play-token-${createHash('sha256').update(TOKEN).digest('hex')}`;
  for (const orderId of [undefined, '', '   ', 'GPA/1234', '__reserved__', '.', '..']) {
    const { lookup } = fakeLookup(paidPurchase({ orderId }));
    assert.deepEqual(await verifyExamUnlockPurchase(request(), lookup), { transactionId: tokenKey });
  }
  assert.notEqual(transactionIdFor({}, 'another-token'), tokenKey);
  assert.equal(transactionIdFor({}, TOKEN), tokenKey);
});

test('keeps a trimmed order id as the replay key', () => {
  assert.equal(transactionIdFor({ orderId: ` ${ORDER_ID} ` }, TOKEN), ORDER_ID);
});

test('classifies Play Developer API failures', () => {
  const httpError = (status) => Object.assign(new Error(`HTTP ${status}`), { response: { status } });

  for (const status of [401, 403]) {
    assert.equal(classifyPlayApiError(httpError(status)).reason, 'misconfigured');
  }
  for (const status of [400, 404, 410]) {
    assert.equal(classifyPlayApiError(httpError(status)).reason, 'rejected');
  }
  for (const status of [408, 429, 500, 502, 503]) {
    assert.equal(classifyPlayApiError(httpError(status)).reason, 'unavailable');
  }
  assert.equal(classifyPlayApiError(new Error('socket hang up')).reason, 'unavailable');

  const original = new PlayVerificationError('misconfigured', 'no credentials');
  assert.equal(classifyPlayApiError(original), original);
});

test('passes a failed lookup on as a classified error', async () => {
  const forbidden = Object.assign(new Error('HTTP 403'), { response: { status: 403 } });
  await assertRejected(verifyExamUnlockPurchase(request(), fakeLookup(forbidden).lookup), 'misconfigured');

  const notFound = Object.assign(new Error('HTTP 404'), { response: { status: 404 } });
  await assertRejected(verifyExamUnlockPurchase(request(), fakeLookup(notFound).lookup), 'rejected');

  await assertRejected(verifyExamUnlockPurchase(request(), fakeLookup(new Error('ETIMEDOUT')).lookup), 'unavailable');
});

// --- Premium subscription (practice mode, 4.2.0) -------------------------------------------------------------------

const UID = 'ayse';
const SUB_ORDER = 'GPA.3311-2222-3333-44444';
const EXPIRY = '2026-12-14T09:00:00.000Z';

/** An active `vifi_premium` subscription bought by UID, as `purchases.subscriptionsv2.get` returns it. */
function activeSubscription(overrides = {}, lineItemOverrides = {}) {
  return {
    kind: 'androidpublisher#subscriptionPurchaseV2',
    regionCode: 'TR',
    startTime: '2026-10-14T09:00:00.000Z',
    subscriptionState: 'SUBSCRIPTION_STATE_ACTIVE',
    latestOrderId: `${SUB_ORDER}..1`,
    acknowledgementState: 'ACKNOWLEDGEMENT_STATE_ACKNOWLEDGED',
    externalAccountIdentifiers: { obfuscatedExternalAccountId: sha256(UID) },
    lineItems: [{
      productId: PREMIUM_SUBSCRIPTION_PRODUCT_ID,
      expiryTime: EXPIRY,
      autoRenewingPlan: { autoRenewEnabled: true },
      offerDetails: { basePlanId: 'monthly' },
      latestSuccessfulOrderId: `${SUB_ORDER}..1`,
      ...lineItemOverrides,
    }],
    ...overrides,
  };
}

const subRequest = (overrides = {}) => ({ purchaseToken: TOKEN, productId: PREMIUM_SUBSCRIPTION_PRODUCT_ID, ...overrides });

test('exposes the Premium subscription product and the entitled states', () => {
  assert.equal(PREMIUM_SUBSCRIPTION_PRODUCT_ID, 'vifi_premium');
  assert.deepEqual([...ENTITLED_SUBSCRIPTION_STATES].sort(), [
    'SUBSCRIPTION_STATE_ACTIVE', 'SUBSCRIPTION_STATE_CANCELED', 'SUBSCRIPTION_STATE_IN_GRACE_PERIOD',
  ]);
});

test('Premium: accepts an active subscription in the App Store payload shape, keyed by the base order id', async () => {
  const { lookup, calls } = fakeLookup(activeSubscription());

  const result = await verifyPremiumSubscription(subRequest(), lookup);

  assert.deepEqual(result, {
    productId: PREMIUM_SUBSCRIPTION_PRODUCT_ID, originalTransactionId: SUB_ORDER, expiresDate: Date.parse(EXPIRY),
  });
  assert.deepEqual(calls, [{ packageName: PACKAGE_NAME, purchaseToken: TOKEN }]);
});

test('Premium: grace period and a cancelled (non-renewing) subscription still count; other states do not', async () => {
  for (const subscriptionState of ['SUBSCRIPTION_STATE_IN_GRACE_PERIOD', 'SUBSCRIPTION_STATE_CANCELED']) {
    const { lookup } = fakeLookup(activeSubscription({ subscriptionState }));
    assert.equal((await verifyPremiumSubscription(subRequest(), lookup)).originalTransactionId, SUB_ORDER, subscriptionState);
  }
  for (const subscriptionState of [
    'SUBSCRIPTION_STATE_EXPIRED', 'SUBSCRIPTION_STATE_ON_HOLD', 'SUBSCRIPTION_STATE_PAUSED', 'SUBSCRIPTION_STATE_PENDING',
    'SUBSCRIPTION_STATE_PENDING_PURCHASE_CANCELED', 'SUBSCRIPTION_STATE_UNSPECIFIED', undefined, 'ACTIVE',
  ]) {
    await assertRejected(verifyPremiumSubscription(subRequest(), fakeLookup(activeSubscription({ subscriptionState })).lookup));
  }
});

test('Premium: the renewal suffix is dropped so every renewal maps to one subscription', async () => {
  for (const orderId of [SUB_ORDER, `${SUB_ORDER}..0`, `${SUB_ORDER}..1`, `${SUB_ORDER}..27`]) {
    const { lookup } = fakeLookup(activeSubscription({ latestOrderId: undefined }, { latestSuccessfulOrderId: orderId }));
    assert.equal((await verifyPremiumSubscription(subRequest(), lookup)).originalTransactionId, SUB_ORDER, orderId);
  }
  // The deprecated top-level `latestOrderId` is the fallback; without any order id the token hash keys it.
  const fallback = fakeLookup(activeSubscription({ latestOrderId: `${SUB_ORDER}..4` }, { latestSuccessfulOrderId: undefined }));
  assert.equal((await verifyPremiumSubscription(subRequest(), fallback.lookup)).originalTransactionId, SUB_ORDER);
  const none = fakeLookup(activeSubscription({ latestOrderId: undefined }, { latestSuccessfulOrderId: undefined }));
  assert.equal(
    (await verifyPremiumSubscription(subRequest(), none.lookup)).originalTransactionId,
    `play-token-${sha256(TOKEN)}`,
  );
  assert.equal(subscriptionIdFor(' GPA.1-2..3 ', TOKEN), 'GPA.1-2');
});

test('Premium: rejects a malformed token or another product without calling Google Play', async () => {
  const cases = [
    ...['', null, undefined, 42, 'x'.repeat(4097)].map((purchaseToken) => subRequest({ purchaseToken })),
    ...[EXAM_UNLOCK_PRODUCT_ID, 'com.BuyukerYazilim.ViFi2.premium.monthly', 'monthly', '', undefined].map((productId) => subRequest({ productId })),
    subRequest({ productId: 'vifi_premium'.padEnd(5000, 'x') }),
  ];
  for (const input of cases) {
    const { lookup, calls } = fakeLookup(activeSubscription());
    await assertRejected(verifyPremiumSubscription(input, lookup));
    assert.equal(calls.length, 0);
  }
});

test('Premium: rejects a subscription without a Premium line item or expiry', async () => {
  const cases = [
    activeSubscription({ lineItems: [] }),
    activeSubscription({ lineItems: undefined }),
    activeSubscription({}, { productId: 'another_subscription' }),
    activeSubscription({}, { expiryTime: undefined }),
    activeSubscription({}, { expiryTime: 'not a date' }),
    null,
    'text',
  ];
  for (const purchase of cases) {
    await assertRejected(verifyPremiumSubscription(subRequest(), fakeLookup(purchase).lookup));
  }
});

test('Premium: the purchase account id is ignored (the subscriptionOwners binding is the account rule)', async () => {
  for (const externalAccountIdentifiers of [
    { obfuscatedExternalAccountId: sha256('mehmet') }, { obfuscatedExternalAccountId: 'x' }, undefined, {},
  ]) {
    const { lookup } = fakeLookup(activeSubscription({ externalAccountIdentifiers }));
    assert.equal((await verifyPremiumSubscription(subRequest(), lookup)).originalTransactionId, SUB_ORDER);
  }
});

test('Premium: with several Premium line items the latest expiry and its order id count', async () => {
  const lineItems = [
    { productId: PREMIUM_SUBSCRIPTION_PRODUCT_ID, expiryTime: '2026-11-20T00:00:00.000Z', latestSuccessfulOrderId: 'GPA.1111-0000-0000-00000..5' },
    { productId: 'another_subscription', expiryTime: '2027-06-01T00:00:00.000Z', latestSuccessfulOrderId: 'GPA.9999-0000-0000-00000' },
    { productId: PREMIUM_SUBSCRIPTION_PRODUCT_ID, expiryTime: '2027-01-14T00:00:00.000Z', latestSuccessfulOrderId: `${SUB_ORDER}..0` },
    { productId: PREMIUM_SUBSCRIPTION_PRODUCT_ID, expiryTime: 'garbage', latestSuccessfulOrderId: 'GPA.2222-0000-0000-00000' },
  ];
  const { lookup } = fakeLookup(activeSubscription({ lineItems }));
  assert.deepEqual(await verifyPremiumSubscription(subRequest(), lookup), {
    productId: PREMIUM_SUBSCRIPTION_PRODUCT_ID, originalTransactionId: SUB_ORDER, expiresDate: Date.parse('2027-01-14T00:00:00.000Z'),
  });
});

test('Premium: rejection messages never quote the client input', async () => {
  const secret = 'client-controlled-value';
  for (const input of [subRequest({ productId: secret }), subRequest({ purchaseToken: secret.repeat(400) })]) {
    await assert.rejects(verifyPremiumSubscription(input, fakeLookup(activeSubscription()).lookup), (error) => {
      assert.ok(!error.message.includes(secret), error.message);
      return true;
    });
  }
});

test('Premium: a failed lookup is a classified error', async () => {
  const http = (status) => Object.assign(new Error(`HTTP ${status}`), { response: { status } });
  await assertRejected(verifyPremiumSubscription(subRequest(), fakeLookup(http(403)).lookup), 'misconfigured');
  await assertRejected(verifyPremiumSubscription(subRequest(), fakeLookup(http(410)).lookup), 'rejected');
  await assertRejected(verifyPremiumSubscription(subRequest(), fakeLookup(http(503)).lookup), 'unavailable');
  await assertRejected(verifyPremiumSubscription(subRequest(), fakeLookup(new Error('ETIMEDOUT')).lookup), 'unavailable');
});

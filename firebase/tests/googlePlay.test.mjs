// Google Play purchase verifier (`functions/googlePlay.js`). The Play Developer API is replaced by a fake lookup, so
// these cover every accept/reject decision without network: input guards (checked before Google Play is called),
// purchase state, product, the exam the purchase was bought for, the replay key, and how API failures are classified.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import {
  EXAM_UNLOCK_PRODUCT_ID,
  PACKAGE_NAME,
  PlayVerificationError,
  classifyPlayApiError,
  transactionIdFor,
  verifyExamUnlockPurchase,
} from '../functions/googlePlay.js';

const TOKEN = 'opaque-purchase-token.AO-J1Oz';
const EXAM_ID = 'itu-blg101-2025-vize';
const ORDER_ID = 'GPA.3372-1234-5678-12345';

/** A paid `exam_unlock` bought for EXAM_ID, as `purchases.products.get` returns it. */
function paidPurchase(overrides = {}) {
  return {
    kind: 'androidpublisher#productPurchase',
    purchaseState: 0,
    consumptionState: 0,
    orderId: ORDER_ID,
    productId: EXAM_UNLOCK_PRODUCT_ID,
    obfuscatedExternalProfileId: EXAM_ID,
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

test('rejects a missing exam id or one longer than Play allows without calling Google Play', async () => {
  for (const examId of ['', undefined, 'e'.repeat(65)]) {
    const { lookup, calls } = fakeLookup(paidPurchase());
    await assertRejected(verifyExamUnlockPurchase(request({ examId }), lookup));
    assert.equal(calls.length, 0);
  }
});

test('accepts an exam id of exactly 64 characters', async () => {
  const examId = 'e'.repeat(64);
  const { lookup } = fakeLookup(paidPurchase({ obfuscatedExternalProfileId: examId }));
  assert.deepEqual(await verifyExamUnlockPurchase(request({ examId }), lookup), { transactionId: ORDER_ID });
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

test('rejects a purchase bought for another exam or for no exam', async () => {
  for (const obfuscatedExternalProfileId of ['another-exam', '', undefined, `${EXAM_ID} `]) {
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

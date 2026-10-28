// Guards of the App Store transaction verifier (`functions/appStore.js`). The happy path needs a transaction
// signed by Apple (real Sandbox/Production), which is not available here, so these cover the input guards and
// that a non-Apple-signed token is rejected — i.e. the server never trusts an unverified transaction.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { verifyExamUnlockTransaction, BUNDLE_ID, EXAM_UNLOCK_PRODUCT_ID } from '../functions/appStore.js';

test('exposes the app identifiers', () => {
  assert.equal(BUNDLE_ID, 'com.BuyukerYazilim.ViFi2');
  assert.equal(EXAM_UNLOCK_PRODUCT_ID, 'com.BuyukerYazilim.ViFi2.exam.unlock');
});

test('rejects an empty transaction', async () => {
  await assert.rejects(() => verifyExamUnlockTransaction(''));
});

test('rejects a non-string transaction', async () => {
  await assert.rejects(() => verifyExamUnlockTransaction(null));
  await assert.rejects(() => verifyExamUnlockTransaction(123));
});

test('rejects a transaction not signed by Apple', async () => {
  // A plausible-looking but unsigned JWS must not verify.
  const fakeJws = 'eyJhbGciOiJFUzI1NiJ9.eyJmb28iOiJiYXIifQ.c2lnbmF0dXJl';
  await assert.rejects(() => verifyExamUnlockTransaction(fakeJws));
});

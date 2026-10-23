import assert from 'node:assert/strict';
import test from 'node:test';

import {
  isAllowedKaspiProviderIp,
  readForwardedClientIp,
  readKaspiProviderQuery,
} from './protocol.mjs';

test('reads a strict exact-amount Kaspi pay request', () => {
  assert.deepEqual(
    readKaspiProviderQuery(
      'https://example.test?command=pay&txn_id=12345&txn_date=20260813122345&account=X5ABCDEF0123456789AB&sum=1000.00',
    ),
    {
      command: 'pay',
      txnId: '12345',
      txnDate: '20260813122345',
      account: 'X5ABCDEF0123456789AB',
      amount: 1000,
    },
  );
});

test('rejects malformed transaction, order and amount fields', () => {
  assert.throws(
    () => readKaspiProviderQuery(
      'https://example.test?command=pay&txn_id=nope&txn_date=20260813122345&account=X5ABCDEF0123456789AB&sum=1000.00',
    ),
    /invalid_txn_id/,
  );
  assert.throws(
    () => readKaspiProviderQuery(
      'https://example.test?command=pay&txn_id=1&txn_date=20260813122345&account=other&sum=1000.00',
    ),
    /invalid_account/,
  );
  assert.throws(
    () => readKaspiProviderQuery(
      'https://example.test?command=pay&txn_id=1&txn_date=20260813122345&account=X5ABCDEF0123456789AB&sum=-1',
    ),
    /invalid_amount/,
  );
});

test('uses a configurable provider IP allowlist', () => {
  const headers = new Headers({ 'cf-connecting-ip': '::ffff:194.187.247.152' });
  assert.equal(readForwardedClientIp(headers), '194.187.247.152');
  assert.equal(isAllowedKaspiProviderIp('194.187.247.152'), true);
  assert.equal(isAllowedKaspiProviderIp('203.0.113.10'), false);
  assert.equal(
    isAllowedKaspiProviderIp('203.0.113.10', '203.0.113.10,203.0.113.11'),
    true,
  );
});

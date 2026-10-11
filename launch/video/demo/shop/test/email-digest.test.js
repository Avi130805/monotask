import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createDigest } from '../src/email/digest.js';

test('digest flushes queued emails together', async () => {
  const batches = [];
  const digest = createDigest({ send: (b) => batches.push(b) });
  digest.add('order-1');
  digest.add('order-2');
  await new Promise((r) => setTimeout(r, 32));
  assert.deepEqual(batches, [['order-1', 'order-2']]);
});

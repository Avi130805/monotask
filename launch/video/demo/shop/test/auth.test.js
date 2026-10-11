import { test } from 'node:test';
import assert from 'node:assert/strict';
import { handleCallback } from '../src/auth/callback.js';

function fakeRes() {
  return {
    status: 0,
    headers: {},
    writeHead(status, headers) { this.status = status; this.headers = headers; },
    end() {},
  };
}

test('google sign-in redirects to the dashboard', async () => {
  const res = fakeRes();
  const url = new URL('http://shop.test/auth/google/callback?code=abc');
  await handleCallback(url, res, async () => ({ email: 'ana@example.com', name: 'Ana' }));
  assert.equal(res.status, 302);
  assert.equal(res.headers.location, '/dashboard');
});

test('failed sign-in goes back home with an error', async () => {
  const res = fakeRes();
  const url = new URL('http://shop.test/auth/google/callback');
  await handleCallback(url, res, async () => { throw new Error('nope'); });
  assert.equal(res.headers.location, '/?error=signin');
});

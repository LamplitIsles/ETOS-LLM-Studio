import { test } from 'node:test';
import assert from 'node:assert/strict';
import { WebAuth } from '../src/cfl/web-auth';

test('synthetic same-origin session signs in, expires, and signs out without cross-origin requests', async () => {
  let state = 'signed_out'; const requests: string[] = []; let cancel = false;
  const auth = new WebAuth({ signIn: { async passkey() { if (cancel) return { error: 'cancelled' }; state = 'signed_in'; return {}; } }, passkey: { async addPasskey() { state = 'signed_in'; return {}; } } },
    async (input, init) => { const url = String(input); requests.push(url); assert.ok(url.startsWith('/api/auth/')); assert.equal(init?.credentials, 'same-origin'); assert.equal(init?.redirect, 'error'); if (url.endsWith('/sign-out')) state = 'signed_out'; return new Response(JSON.stringify(url.endsWith('/status') ? { mode: 'passkey', state } : { ok: true })); }, () => true);
  assert.equal(await auth.status(), 'signed_out'); await auth.signIn(); assert.equal(await auth.status(), 'signed_in');
  state = 'signed_out'; assert.equal(await auth.status(), 'signed_out'); cancel = true; await assert.rejects(auth.signIn(), /authentication_failed/);
  await auth.signOut(); assert.ok(requests.includes('/api/auth/sign-out'));
});

test('injected fetch preserves same-origin status, pairing and sign-out requests and errors', async () => {
  const requests: { path: string; init?: RequestInit }[] = [];
  let status = 200, state = 'signed_in', additions = 0;
  const passkeys = { signIn: { async passkey() { return {}; } }, passkey: { async addPasskey(options: { createSession: true }) { assert.equal(options.createSession, true); additions++; return {}; } } };
  const auth = new WebAuth(passkeys, async (input, init) => {
    const path = String(input); requests.push({ path, init });
    return new Response(path.endsWith('/status') ? JSON.stringify({ mode: 'passkey', state }) : '{}', { status });
  }, () => true);
  assert.equal(await auth.status(), 'signed_in'); await auth.pair('test-code'); await auth.signOut();
  assert.deepEqual(requests.map(request => request.path), ['/api/auth/status', '/api/auth/pairing', '/api/auth/status', '/api/auth/sign-out']);
  assert.ok(requests.every(({ init }) => init?.credentials === 'same-origin' && init?.redirect === 'error'));
  assert.equal(requests[0].init?.cache, 'no-store');
  assert.equal(requests[1].init?.method, 'POST'); assert.equal(requests[1].init?.body, '{"code":"test-code"}');
  assert.equal(requests[3].init?.method, 'POST'); assert.equal(requests[3].init?.body, '{}'); assert.equal(additions, 1);
  status = 403;
  await assert.rejects(auth.status(), /unavailable/);
  await assert.rejects(auth.pair('test-code'), /pairing_failed/); assert.equal(additions, 1);
  await assert.rejects(auth.signOut(), /unavailable/);
  status = 200; state = 'invalid'; await assert.rejects(auth.status(), /invalid_status/);
});

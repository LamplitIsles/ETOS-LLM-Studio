import { test } from 'node:test';
import assert from 'node:assert/strict';
import { NativeAuth, type Grant } from '../src/cfl/native-auth';

const origin = 'https://cfl.example';
function harness() {
  const grants = new Map<string, Grant>(); let last = ''; let calls = 0; let fail = false; let cancel = false; let corrupt = false;
  const auth = new NativeAuth({ store: { async load(o) { return grants.get(o) ?? null; }, async save(o, value) { grants.set(o, value); }, async remove(o) { grants.delete(o); } },
    random: async () => 'test-random', challenge: async () => 'test-challenge', now: () => 1000,
    browser: async url => { last = url; return cancel ? null : `etosllmstudio://auth/callback?code=synthetic&state=${corrupt ? 'wrong' : 'test-random'}&iss=${encodeURIComponent(origin + '/api/auth')}`; },
    fetch: async (url) => { calls++; if (fail) throw new Error('lost'); const response = new Response(JSON.stringify({ access_token: 'synthetic-access', refresh_token: 'synthetic-refresh', expires_in: 3600, token_type: 'Bearer' })); Object.defineProperty(response, 'url', { value: String(url) }); return response; },
  }); auth.select(origin);
  return { auth, grants, calls: () => calls, last: () => last, fail: (v: boolean) => { fail = v; }, cancel: () => { cancel = true; }, corrupt: () => { corrupt = true; } };
}
test('native authorization uses fixed PKCE client and validates callback', async () => {
  const h = harness(); await h.auth.signIn(); const url = new URL(h.last());
  assert.equal(url.searchParams.get('redirect_uri'), 'etosllmstudio://auth/callback'); assert.equal(url.searchParams.get('code_challenge_method'), 'S256');
  assert.equal(await h.auth.token(), 'synthetic-access'); assert.equal(h.calls(), 1);
  const wrong = harness(); wrong.corrupt(); await assert.rejects(wrong.auth.signIn(), /invalid_callback/); assert.equal(wrong.calls(), 0);
  const cancelled = harness(); cancelled.cancel(); await assert.rejects(cancelled.auth.signIn(), /cancelled/); assert.equal(cancelled.calls(), 0);
});
test('lost refresh remains pending across attempts and never replays', async () => {
  const h = harness(); h.grants.set(origin, { accessToken: 'old', refreshToken: 'single-use', expiresAt: 0, pending: false }); h.fail(true);
  await assert.rejects(h.auth.token(), /unavailable/); assert.equal(h.grants.get(origin)?.pending, true);
  await assert.rejects(h.auth.token(), /authorization_required/); assert.equal(h.calls(), 1);
});
test('concurrent refresh is shared', async () => {
  const h = harness(); h.grants.set(origin, { accessToken: 'old', refreshToken: 'single-use', expiresAt: 0, pending: false });
  const [a,b] = await Promise.all([h.auth.token(), h.auth.token()]); assert.equal(a,b); assert.equal(h.calls(),1);
  assert.throws(() => h.auth.select('http://cfl.example'), /invalid_origin/);
});
test('sign-out wins a delayed secure-store write', async () => {
  let stored: Grant | null = { accessToken: 'old', refreshToken: 'old-refresh', expiresAt: 0, pending: false };
  let release!: () => void, writing!: () => void;
  const started = new Promise<void>(r => { writing = r; });
  const hold = new Promise<void>(r => { release = r; });
  const auth = new NativeAuth({ store: { async load() { return stored; }, async save(_, grant) { writing(); await hold; stored = grant; }, async remove() { stored = null; } }, random: async () => 'random', challenge: async () => 'challenge', browser: async () => null, fetch: async () => { throw Error('must not dispatch'); }, now: () => 1000 });
  auth.select(origin); const token = auth.token(); await started; const logout = auth.signOut(); release();
  await assert.rejects(token, /superseded/); await logout; assert.equal(stored, null);
});
test('a grant bound to another origin cannot be used by transport', async () => {
  const h = harness(); await assert.rejects(h.auth.tokenFor('https://other.example'), /superseded/); assert.equal(h.calls(), 0);
});
test('switching origin drops late authorization results', async () => {
  let finish!: (value: Response) => void, dispatched!: () => void;
  const sent = new Promise<void>(r => { dispatched = r; }); const grants = new Map<string, Grant>();
  const auth = new NativeAuth({ store: { async load(o) { return grants.get(o) ?? null; }, async save(o, v) { grants.set(o,v); }, async remove(o) { grants.delete(o); } }, random: async () => 's', challenge: async () => 'challenge', now: () => 0,
    browser: async () => `etosllmstudio://auth/callback?code=synthetic&state=s&iss=${encodeURIComponent(origin + '/api/auth')}`,
    fetch: async () => { dispatched(); return new Promise<Response>(r => { finish = r; }); } });
  auth.select(origin); const attempt = auth.signIn(); await sent; auth.select('https://other.example');
  const response = new Response(JSON.stringify({ access_token: 'a', refresh_token: 'r', expires_in: 3600, token_type: 'Bearer' })); Object.defineProperty(response, 'url', { value: `${origin}/api/auth/oauth2/token` }); finish(response);
  await assert.rejects(attempt, /superseded/); assert.equal(grants.size, 0);
});
test('an explicit status check can force a valid-looking grant to refresh', async () => {
  const h = harness(); h.grants.set(origin, { accessToken: 'old', refreshToken: 'single-use', expiresAt: 1000000, pending: false });
  assert.equal(await h.auth.tokenFor(origin, true), 'synthetic-access'); assert.equal(h.calls(), 1);
});

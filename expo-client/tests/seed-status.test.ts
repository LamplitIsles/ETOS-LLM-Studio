import { test } from 'node:test';
import assert from 'node:assert/strict';
import { developmentSeedAvailable, developmentSeedStatus, createDevelopmentSeedChat } from '../src/cfl/seed.web';

test('seed status is guarded, credential-free, validated and reused on reconnect', async t => {
  const savedDev = Object.getOwnPropertyDescriptor(globalThis, '__DEV__');
  const savedWindow = Object.getOwnPropertyDescriptor(globalThis, 'window');
  const savedFlag = process.env.EXPO_PUBLIC_ETOS_SYNTHETIC_SEED;
  const savedLan = process.env.EXPO_PUBLIC_ETOS_SEED_LAN_HOST;
  t.after(() => {
    if (savedDev) Object.defineProperty(globalThis, '__DEV__', savedDev); else Reflect.deleteProperty(globalThis, '__DEV__');
    if (savedWindow) Object.defineProperty(globalThis, 'window', savedWindow); else Reflect.deleteProperty(globalThis, 'window');
    if (savedFlag === undefined) delete process.env.EXPO_PUBLIC_ETOS_SYNTHETIC_SEED; else process.env.EXPO_PUBLIC_ETOS_SYNTHETIC_SEED = savedFlag;
    if (savedLan === undefined) delete process.env.EXPO_PUBLIC_ETOS_SEED_LAN_HOST; else process.env.EXPO_PUBLIC_ETOS_SEED_LAN_HOST = savedLan;
  });
  Object.defineProperty(globalThis, '__DEV__', { configurable: true, writable: true, value: true });
  Object.defineProperty(globalThis, 'window', { configurable: true, writable: true, value: { location: { origin: 'http://localhost:8091' } } });
  process.env.EXPO_PUBLIC_ETOS_SYNTHETIC_SEED = '1';
  delete process.env.EXPO_PUBLIC_ETOS_SEED_LAN_HOST;
  let body: unknown = { mode: 'passkey', state: 'signed_in' };
  let status = 200, redirected = false;
  const calls: { input: unknown; init?: RequestInit }[] = [];
  t.mock.method(globalThis, 'fetch', async (input: string | URL | Request, init?: RequestInit) => {
    calls.push({ input, init });
    const response = new Response(JSON.stringify(body), { status });
    if (redirected) Object.defineProperty(response, 'redirected', { value: true });
    return response;
  });
  assert.equal(developmentSeedAvailable(), true);
  for (const state of ['setup', 'signed_out', 'signed_in'] as const) {
    body = { mode: 'passkey', state };
    assert.equal(await developmentSeedStatus(), state);
  }
  assert.deepEqual(calls[0], { input: '/api/auth/status', init: { credentials: 'omit', cache: 'no-store', redirect: 'error' } });
  const controller = createDevelopmentSeedChat().controller as unknown as { checkAuthorization(): Promise<boolean> };
  assert.equal(await controller.checkAuthorization(), true);
  body = { mode: 'passkey', state: 'signed_out' };
  assert.equal(await controller.checkAuthorization(), false);
  for (const value of [null, {}, { mode: 'other', state: 'signed_in' }, { mode: 'passkey', state: 'unknown' }, { mode: 'passkey', state: ['signed_in'] }]) {
    body = value;
    await assert.rejects(developmentSeedStatus(), /unavailable/);
  }
  body = { mode: 'passkey', state: 'signed_in' };
  status = 503;
  await assert.rejects(developmentSeedStatus(), /unavailable/);
  status = 200; redirected = true;
  await assert.rejects(developmentSeedStatus(), /unavailable/);
  redirected = false;
  const count = calls.length;
  for (const [dev, flag, origin] of [[false, '1', 'http://localhost:8091'], [true, '', 'http://localhost:8091'], [true, '1', 'https://example.com'], [true, '1', 'http://localhost:3090']] as const) {
    Object.defineProperty(globalThis, '__DEV__', { configurable: true, writable: true, value: dev });
    process.env.EXPO_PUBLIC_ETOS_SYNTHETIC_SEED = flag;
    Object.defineProperty(globalThis, 'window', { configurable: true, writable: true, value: { location: { origin } } });
    await assert.rejects(developmentSeedStatus(), /synthetic_seed_unavailable/);
  }
  assert.equal(calls.length, count, 'disallowed environments must not call fetch');
});

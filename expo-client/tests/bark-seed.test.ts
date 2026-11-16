import { test } from 'node:test';
import assert from 'node:assert/strict';
import http, { type RequestOptions } from 'node:http';
import { once } from 'node:events';
import { createSeedProxy, seedRequest } from '../scripts/seed-proxy.mjs';
import { isSeedApiRequest, isTestBarkFixtureRequest } from '../src/cfl/seed-paths';
import { createDevelopmentSeedChat } from '../src/cfl/seed.web';

const path = '/api/bark/settings';
const testPath = '/api/bark/test';
const invalid: [string, string][] = [['GET', `${path}?`], ['POST', `${path}?x=1`], ['GET', `${path}/extra`], ['POST', `${path}/`], ['PUT', path], ['DELETE', path], ['get', path], ['GET', '/api/bark%2Fsettings'], ['GET', testPath], ['PUT', testPath], ['POST', `${testPath}?`], ['POST', `${testPath}/extra`]];

test('synthetic browser transport allows only exact Bark fixture paths without credentials', async t => {
  const savedDev = Object.getOwnPropertyDescriptor(globalThis, '__DEV__'), savedWindow = Object.getOwnPropertyDescriptor(globalThis, 'window');
  const flag = process.env.EXPO_PUBLIC_ETOS_SYNTHETIC_SEED;
  t.after(() => {
    if (savedDev) Object.defineProperty(globalThis, '__DEV__', savedDev); else Reflect.deleteProperty(globalThis, '__DEV__');
    if (savedWindow) Object.defineProperty(globalThis, 'window', savedWindow); else Reflect.deleteProperty(globalThis, 'window');
    if (flag === undefined) delete process.env.EXPO_PUBLIC_ETOS_SYNTHETIC_SEED; else process.env.EXPO_PUBLIC_ETOS_SYNTHETIC_SEED = flag;
  });
  Object.defineProperty(globalThis, '__DEV__', { configurable: true, value: true });
  Object.defineProperty(globalThis, 'window', { configurable: true, value: { location: { origin: 'http://localhost:8091' } } });
  process.env.EXPO_PUBLIC_ETOS_SYNTHETIC_SEED = '1';
  const calls: { input: unknown; init?: RequestInit }[] = [];
  t.mock.method(globalThis, 'fetch', async (input: string | URL | Request, init?: RequestInit) => { calls.push({ input, init }); return Response.json({ configured: false, enabled: false }); });
  const { media } = createDevelopmentSeedChat();
  for (const method of ['GET', 'POST']) {
    assert.equal(isSeedApiRequest(method, path), false); assert.equal(isTestBarkFixtureRequest(method, path), true);
    await media.request(path, { method });
  }
  assert.equal(isSeedApiRequest('POST', testPath), false); assert.equal(isTestBarkFixtureRequest('POST', testPath), true);
  await media.request(testPath, { method: 'POST' });
  for (const [method, candidate] of invalid) { assert.equal(isTestBarkFixtureRequest(method, candidate), false); await assert.rejects(media.request(candidate, { method }), { message: 'invalid_media' }); }
  assert.equal(calls.length, 3);
  for (const call of calls) { assert.ok(call.input === path || call.input === testPath); assert.equal(call.init?.credentials, 'omit'); assert.equal(call.init?.redirect, 'error'); }
});

test('only test fixture proxy forwards exact Bark paths; fixed policy never contacts upstream', async t => {
  assert.throws(() => createSeedProxy({ seedRequest, metroRequest: async () => { throw Error('unused'); }, testOnlyBarkFixture: true }), /forbidden/);
  const seen: { method?: string; url?: string; headers: http.IncomingHttpHeaders }[] = [];
  const fake = http.createServer((req, res) => { seen.push({ method: req.method, url: req.url, headers: req.headers }); req.resume(); res.writeHead(200, { 'content-type': 'application/json' }).end('{}'); });
  fake.listen(0, '127.0.0.1'); await once(fake, 'listening'); const fakePort = (fake.address() as { port: number }).port;
  const upstream = async (options: RequestOptions) => http.request({ ...options, hostname: '127.0.0.1', port: fakePort });
  const make = async (enabled: boolean) => { const proxy: http.Server = createSeedProxy({ seedRequest: upstream, metroRequest: upstream, testOnlyBarkFixture: enabled }); proxy.listen(0, '127.0.0.1'); await once(proxy, 'listening'); return proxy; };
  const fixed = await make(false), fixture = await make(true);
  t.after(() => { fixed.closeAllConnections(); fixed.close(); fixture.closeAllConnections(); fixture.close(); fake.closeAllConnections(); fake.close(); });
  const request = (proxy: http.Server, method: string, url: string, headers: Record<string, string> = {}) => new Promise<number>((resolve, reject) => {
    const req = http.request({ hostname: '127.0.0.1', port: (proxy.address() as { port: number }).port, method, path: url, headers: { host: 'localhost:8091', origin: 'http://localhost:8091', cookie: 'fake-cookie', authorization: 'Bearer fake-token', ...headers } }, res => { res.resume(); res.on('end', () => resolve(res.statusCode!)); });
    req.on('error', reject); req.end();
  });
  for (const method of ['GET', 'POST']) assert.equal(await request(fixed, method, path), 404);
  assert.equal(await request(fixed, 'POST', testPath), 404);
  assert.equal(seen.length, 0);
  for (const method of ['GET', 'POST']) assert.equal(await request(fixture, method, path), 200);
  assert.equal(await request(fixture, 'POST', testPath), 200);
  for (const [method, candidate] of invalid.filter(([method]) => method !== 'get')) assert.equal(await request(fixture, method, candidate), 404);
  assert.equal(await request(fixture, 'POST', path, { origin: '' }), 404);
  assert.equal(await request(fixture, 'GET', path, { origin: 'http://evil.invalid' }), 403);
  assert.equal(await request(fixture, 'GET', path, { host: 'evil.invalid:8091' }), 403);
  assert.equal(await request(fixture, 'GET', path, { 'sec-fetch-site': 'cross-site' }), 403);
  assert.deepEqual(seen.map(x => [x.method, x.url]), [['GET', path], ['POST', path], ['POST', testPath]]);
  assert.ok(seen.every(x => !x.headers.cookie && !x.headers.authorization));
});

test('test-only fixture never sends Bark and requires the exact JSON request', async () => {
  const { createFixtureMedia } = await import('./fixtures/fixture-attachments');
  const media = createFixtureMedia();
  const request = (body: string, contentType = 'application/json') => media.request(testPath, { method: 'POST', headers: { 'content-type': contentType }, body });
  const response = await request('{}'); assert.equal(response.status, 409); assert.equal((await response.json()).error.code, 'bark_not_configured');
  for (const body of ['', 'null', '[]', '{"extra":true}']) assert.equal((await request(body)).status, 400);
  assert.equal((await request('{}', 'text/plain')).status, 400);
});

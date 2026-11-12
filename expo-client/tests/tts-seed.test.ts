import { test } from 'node:test';
import assert from 'node:assert/strict';
import http, { type RequestOptions } from 'node:http';
import { once } from 'node:events';
import { createSeedProxy, seedRequest } from '../scripts/seed-proxy.mjs';
import { startFixtureSeedHost } from './fixtures/seed-host';

async function launch(testOnlyTtsFixture: boolean) {
  const host = await startFixtureSeedHost(); const forwarded: RequestOptions[] = [];
  const proxy: http.Server = createSeedProxy({ seedRequest: async (options: RequestOptions) => { forwarded.push(options); return host.request(options); }, metroRequest: async () => { throw Error('no Metro'); }, testOnlyTtsFixture });
  proxy.listen(0, '127.0.0.1'); await once(proxy, 'listening'); const port = (proxy.address() as { port: number }).port;
  const request = (method: string, path: string, headers: Record<string, string> = {}, body?: unknown) => new Promise<{ status: number; data: any }>((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, method, path, headers: { host: 'localhost:8091', origin: 'http://localhost:8091', cookie: 'fixture-cookie', authorization: 'Bearer fixture-token', 'content-type': 'application/json', ...headers } }, res => { const chunks: Buffer[] = []; res.on('data', chunk => chunks.push(chunk)); res.on('end', () => { const text = Buffer.concat(chunks).toString(); resolve({ status: res.statusCode!, data: text ? JSON.parse(text) : null }); }); }); req.on('error', reject); req.end(body === undefined ? undefined : JSON.stringify(body));
  });
  const close = async () => { proxy.closeAllConnections(); await new Promise<void>(resolve => proxy.close(() => resolve())); await host.close(); };
  return { host, forwarded, request, close };
}

test('fixed seed policy permits only safe settings, refuses key and external list without reaching seed', async () => {
  assert.throws(() => createSeedProxy({ seedRequest, metroRequest: async () => { throw Error('unused'); }, testOnlyTtsFixture: true }), /forbidden/);
  const f = await launch(false);
  try {
    assert.equal((await f.request('GET', '/api/tts/settings')).status, 200);
    assert.equal((await f.request('POST', '/api/tts/settings', {}, { provider: 'minimax', voice: 'fixture', speed: null })).status, 200);
    const key = await f.request('POST', '/api/tts/settings/key', {}, { provider: 'elevenlabs', apiKey: 'fixture-key' }); assert.equal(key.status, 404); assert.equal(key.data.error.code, 'tts_unsupported');
    assert.equal((await f.request('GET', '/api/tts/elevenlabs/voices')).status, 404); assert.equal(f.forwarded.length, 2);
    for (const [method, path] of [['GET','/api/tts/settings?x=1'], ['POST','/api/tts/settings?x=1'], ['PUT','/api/tts/settings'], ['POST','/api/tts/settings/extra']]) assert.equal((await f.request(method, path)).status, 404);
    assert.equal((await f.request('POST', '/api/tts/settings', { origin: '' }, {})).status, 404);
    assert.equal((await f.request('POST', '/api/tts/settings', { origin: 'http://evil.invalid' }, {})).status, 403);
    assert.equal((await f.request('GET', '/api/tts/settings', { host: 'evil.invalid:8091' })).status, 403);
    assert.equal((await f.request('GET', '/api/tts/settings', { 'sec-fetch-site': 'cross-site' })).status, 403);
    assert.equal(f.forwarded.length, 2);
  } finally { await f.close(); }
});

test('test-only proxy exposes exact synthetic key/list endpoints and fake pagination without external requests', async () => {
  const f = await launch(true);
  try {
    const noKey = await f.request('GET', '/api/tts/elevenlabs/voices'); assert.equal(noKey.status, 400); assert.equal(noKey.data.error.code, 'tts_key_required');
    const key = await f.request('POST', '/api/tts/settings/key', {}, { provider: 'elevenlabs', apiKey: 'fixture-test-key' }); assert.equal(key.status, 200); assert.equal(key.data.configured.elevenlabs, true); assert.ok(!JSON.stringify(key.data).includes('fixture-test-key'));
    const first = await f.request('GET', '/api/tts/elevenlabs/voices'); assert.equal(first.data.nextCursor, 'fixture-next');
    const second = await f.request('GET', '/api/tts/elevenlabs/voices?cursor=fixture-next'); assert.equal(second.data.nextCursor, null);
    const seen = f.forwarded.length;
    for (const [method, path] of [['GET','/api/tts/elevenlabs/voices?cursor='], ['GET','/api/tts/elevenlabs/voices?cursor=x&cursor=y'], ['GET','/api/tts/elevenlabs/voices?cursor=%ZZ'], ['GET','/api/tts/elevenlabs/voices?other=x'], ['POST','/api/tts/settings/key?x=1'], ['GET','/api/tts/settings/key'], ['POST','/api/tts/elevenlabs/voices']]) assert.equal((await f.request(method, path)).status, 404);
    assert.equal((await f.request('POST', '/api/tts/settings/key', { origin: '' }, { provider: 'elevenlabs', apiKey: 'fixture-x' })).status, 404);
    assert.equal((await f.request('GET', '/api/tts/elevenlabs/voices', { origin: 'http://evil.invalid' })).status, 403); assert.equal(f.forwarded.length, seen);
    for (const call of f.forwarded) { const headers = call.headers as Record<string, string>; assert.equal(headers.cookie, undefined); assert.equal(headers.authorization, undefined); }
    const rejected = await f.request('POST', '/api/tts/settings/key', {}, { provider: 'elevenlabs', apiKey: 'not-a-fixture-key' }); assert.equal(rejected.status, 400);
    f.host.setStatus('signed_out'); assert.equal((await f.request('GET', '/api/tts/settings')).status, 401);
  } finally { await f.close(); }
});

import { test } from 'node:test';
import assert from 'node:assert/strict';
import http, { type RequestOptions } from 'node:http';
import { once } from 'node:events';
import { createSeedProxy } from '../scripts/seed-proxy.mjs';
import { startFixtureSeedHost } from './fixtures/seed-host';
import { fixtureImageBase64 } from './fixtures/fixture-art';

test('test-only seed proxy restricts background paths, strips credentials, and carries raw bytes', async t => {
  const host = await startFixtureSeedHost(), forwarded: RequestOptions[] = [];
  const proxy: http.Server = createSeedProxy({ seedRequest: async (options: RequestOptions) => { forwarded.push(options); return host.request(options); }, metroRequest: async () => { throw Error('no Metro'); } });
  proxy.listen(0, '127.0.0.1'); await once(proxy, 'listening');
  t.after(async () => { proxy.closeAllConnections(); await new Promise<void>(resolve => proxy.close(() => resolve())); await host.close(); });
  const port = (proxy.address() as { port: number }).port, source = Buffer.from(fixtureImageBase64, 'base64');
  const request = (method: string, path: string, headers: Record<string, string> = {}, body?: Buffer) => new Promise<{ status: number; bytes: Buffer }>((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, method, path, headers: { host: 'localhost:8091', origin: 'http://localhost:8091', cookie: 'synthetic-secret', authorization: 'Bearer synthetic-secret', 'content-type': 'image/png', ...headers } }, res => { const chunks: Buffer[] = []; res.on('data', chunk => chunks.push(chunk)); res.on('end', () => resolve({ status: res.statusCode!, bytes: Buffer.concat(chunks) })); }); req.on('error', reject); req.end(body);
  });
  assert.deepEqual(JSON.parse((await request('GET', '/api/background-settings')).bytes.toString()), { landscape: false, portrait: false });
  assert.deepEqual(JSON.parse((await request('POST', '/api/background-settings/landscape', {}, source)).bytes.toString()), { landscape: true, portrait: false });
  assert.deepEqual((await request('GET', '/api/backgrounds/portrait')).bytes, source);
  assert.deepEqual(JSON.parse((await request('POST', '/api/background-settings/portrait', {}, source)).bytes.toString()), { landscape: true, portrait: true });
  for (const [method, path] of [['GET','/api/background-settings?x=1'], ['GET','/api/background-settings/landscape'], ['POST','/api/background-settings'], ['POST','/api/background-settings/portrait?x=1'], ['POST','/api/background-settings/other'], ['PUT','/api/background-settings/portrait'], ['DELETE','/api/background-settings/portrait']]) assert.equal((await request(method, path)).status, 404);
  assert.equal((await request('POST', '/api/background-settings/portrait', { origin: '' }, source)).status, 404);
  assert.equal((await request('POST', '/api/background-settings/portrait', { origin: 'http://evil.invalid' }, source)).status, 403);
  assert.equal((await request('GET', '/api/background-settings', { host: 'evil.invalid:8091' })).status, 403);
  assert.equal((await request('GET', '/api/background-settings', { 'sec-fetch-site': 'cross-site' })).status, 403);
  assert.equal(forwarded.length, 4);
  for (const call of forwarded) { const headers = call.headers as Record<string, string>; assert.equal(headers.cookie, undefined); assert.equal(headers.authorization, undefined); }
  host.setStatus('signed_out'); assert.equal((await request('GET', '/api/background-settings')).status, 401);
});

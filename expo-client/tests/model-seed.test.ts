import { test } from 'node:test';
import assert from 'node:assert/strict';
import http, { type RequestOptions } from 'node:http';
import { once } from 'node:events';
import { createSeedProxy } from '../scripts/seed-proxy.mjs';
import { startFixtureSeedHost } from './fixtures/seed-host';

test('seed proxy allows only exact model GET/POST and strips credentials', async t => {
  const host = await startFixtureSeedHost(); const forwarded: RequestOptions[] = [];
  const proxy: http.Server = createSeedProxy({ seedRequest: async (options: RequestOptions) => { forwarded.push(options); return host.request(options); }, metroRequest: async () => { throw Error('not Metro'); } });
  proxy.listen(0, '127.0.0.1'); await once(proxy, 'listening');
  t.after(async () => { proxy.closeAllConnections(); await new Promise<void>(r => proxy.close(() => r())); await host.close(); });
  const port = (proxy.address() as { port: number }).port;
  const request = (method: string, path: string, headers: Record<string,string> = {}, body?: unknown) => new Promise<{ status: number; data: any }>((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, method, path, headers: { host: 'localhost:8091', origin: 'http://localhost:8091', cookie: 'fixture=secret', authorization: 'Bearer fixture-secret', 'content-type': 'application/json', ...headers } }, res => { const chunks: Buffer[] = []; res.on('data', chunk => chunks.push(chunk)); res.on('end', () => { const text = Buffer.concat(chunks).toString(); resolve({ status: res.statusCode!, data: text ? JSON.parse(text) : null }); }); });
    req.on('error', reject); req.end(body === undefined ? undefined : JSON.stringify(body));
  });
  const first = await request('GET', '/api/chat/models'); assert.equal(first.status, 200); assert.equal(first.data.currentModel, 'gpt-6.1-sol');
  const choice = { sessionId: 'fixture-session', expectedModel: 'gpt-6.1-sol', expectedFast: true, model: 'gpt-6.1-terra', fast: false };
  const changed = await request('POST', '/api/chat/models', {}, choice); assert.equal(changed.status, 200); assert.equal(changed.data.currentModel, choice.model);
  const conflict = await request('POST', '/api/chat/models', {}, choice); assert.equal(conflict.status, 409); assert.equal(conflict.data.error.code, 'stale_model');
  for (const [method, path] of [['GET', '/api/chat/models?x=1'], ['POST', '/api/chat/models?x=1'], ['GET', '/api/chat/models/extra'], ['PUT', '/api/chat/models'], ['DELETE', '/api/chat/models'], ['GET', '/api/chat/model']]) assert.equal((await request(method, path)).status, 404);
  assert.equal((await request('POST', '/api/chat/models', { origin: '' }, choice)).status, 404);
  assert.equal((await request('POST', '/api/chat/models', { origin: 'http://evil.invalid' }, choice)).status, 403);
  assert.equal((await request('GET', '/api/chat/models', { host: 'evil.invalid:8091' })).status, 403);
  assert.equal((await request('GET', '/api/chat/models', { 'sec-fetch-site': 'cross-site' })).status, 403);
  assert.equal(forwarded.length, 3);
  for (const call of forwarded) { const headers = call.headers as Record<string, string>; assert.equal(headers.cookie, undefined); assert.equal(headers.authorization, undefined); }
  host.setStatus('signed_out'); assert.equal((await request('GET', '/api/chat/models')).status, 401);
});

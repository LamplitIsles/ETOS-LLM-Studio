import { test } from 'node:test';
import assert from 'node:assert/strict';
import http, { type RequestOptions } from 'node:http';
import { once } from 'node:events';
import WebSocket, { WebSocketServer } from 'ws';
import { createChatHost, type ChatBackend, type ChatChange } from '../vendor/contracts/src/server';
import { openChat } from '../vendor/contracts/src/client';
import type { ChatView } from '../vendor/contracts/src/index';
import { createSeedProxy } from '../scripts/seed-proxy.mjs';
import { loadAppearance, loadAppearanceImage } from '../src/cfl/appearance';

const initial: ChatView = { version: 2, sessionId: 'synthetic-proxy-session', name: 'test', activeTurnId: null, contextUsage: { tokens: null, capacity: null }, compaction: null, messages: [], before: 'cursor', capabilities: { text: true, steer: true, stop: true, images: false } };

test('loopback development proxy carries synthetic chat, history, replies and image without credentials or cross-origin access', async t => {
  let submissions = 0;
  const scope = Symbol(); let changed!: (event: ChatChange) => void;
  const seen: http.IncomingHttpHeaders[] = [];
  const backend = {
    async read() { return initial; }, subscribe(fn: typeof changed) { changed = fn; return { scope, close() {} }; },
    async history() { return { messages: [{ id: 'old', role: 'user', text: '合成历史', createdAt: 1, operationId: null, turnId: null }], before: null }; },
    async submit(input: { operationId: string }) { submissions++; setTimeout(() => changed({ type: 'update', scope, state: { streamingReply: { id: 'fake-reply', turnId: null, createdAt: 2, text: '合成回复' } } }), 5); return { operationId: input.operationId, attempt: 1, state: 'submitted', messageId: 'synthetic-message', turnId: null, error: null }; },
    async lookup(id: string) { return { operationId: id, attempt: 1, state: 'submitted', messageId: 'synthetic-message', turnId: null, error: null }; },
  } as unknown as ChatBackend;
  const host = await createChatHost(backend, error => { throw error; });
  const fake = http.createServer((req, res) => {
    seen.push(req.headers);
    res.setHeader('Set-Cookie', 'not-a-real-cookie=1'); res.setHeader('Access-Control-Allow-Origin', '*');
    if (req.url === '/api/auth/status') { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end('{"mode":"passkey","state":"signed_in"}'); }
    else if (req.url === '/api/chat/appearance') { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify({ companionName: 'Mica', userName: '', companionAvatar: '/api/avatars/companion', backgrounds: { landscape: '/api/backgrounds/landscape', portrait: '/api/backgrounds/portrait' } })); }
    else if (['/api/avatars/companion', '/api/backgrounds/landscape', '/api/backgrounds/portrait'].includes(req.url ?? '')) { res.writeHead(200, { 'Content-Type': 'image/png' }); res.end('synthetic-appearance'); }
    else if (req.url === '/api/chat/media/picture/preview') { res.writeHead(200, { 'Content-Type': 'image/png' }); res.end('synthetic-image'); }
    else if (req.url === '/api/chat/workspace-image?path=folder%2Fimage%20%2520.png') { res.writeHead(200, { 'Content-Type': 'image/png' }); res.end('synthetic-workspace-image'); }
    else { res.writeHead(404); res.end(); }
  });
  const wss = new WebSocketServer({ noServer: true });
  fake.on('upgrade', (req, socket, head) => {
    seen.push(req.headers);
    wss.handleUpgrade(req, socket, head, ws => {
      const peer = host.connect({ send(data) { ws.send(data); }, close() { ws.close(); } }, async () => true);
      ws.on('message', data => { void peer.receive(data.toString()); });
      ws.on('close', () => peer.close());
    });
  });
  fake.listen(0, '127.0.0.1'); await once(fake, 'listening');
  const fakePort = (fake.address() as { port: number }).port;
  const request = async (options: RequestOptions) => http.request({ ...options, host: '127.0.0.1', port: fakePort });
  const proxy: http.Server = createSeedProxy({ seedRequest: request, metroRequest: request, lanHost: '192.168.50.2' });
  proxy.listen(0, '127.0.0.1'); await once(proxy, 'listening');
  t.after(async () => { host.close(); wss.close(); proxy.closeAllConnections(); fake.closeAllConnections(); await Promise.all([new Promise<void>(r => proxy.close(() => r())), new Promise<void>(r => fake.close(() => r()))]); });
  const port = (proxy.address() as { port: number }).port;
  const get = (path: string, options: { method?: string; headers?: Record<string, string> } = {}) => new Promise<{ status: number; headers: http.IncomingHttpHeaders; body: string }>((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, path, method: options.method ?? 'GET', headers: { host: 'localhost:8091', ...options.headers } }, res => { let body = ''; res.setEncoding('utf8'); res.on('data', chunk => { body += chunk; }); res.on('end', () => resolve({ status: res.statusCode!, headers: res.headers, body })); }); req.on('error', reject); req.end();
  });
  const image = await get('/api/chat/media/picture/preview', { headers: { origin: 'http://localhost:8091', cookie: 'secret=x', authorization: 'Bearer secret', forwarded: 'host=other', 'x-forwarded-host': 'other' } });
  assert.equal(image.body, 'synthetic-image'); assert.equal(image.headers['set-cookie'], undefined); assert.equal(image.headers['access-control-allow-origin'], undefined);
  const workspace = '/api/chat/workspace-image?path=folder%2Fimage%20%2520.png';
  assert.equal((await get(workspace, { headers: { origin: 'http://localhost:8091', cookie: 'secret=x', authorization: 'Bearer secret' } })).body, 'synthetic-workspace-image');
  assert.equal((await get(workspace, { headers: { origin: 'http://evil.example' } })).status, 403);
  assert.equal((await get(`${workspace}&retry=1`)).status, 404);
  assert.equal((await get(workspace, { method: 'POST', headers: { origin: 'http://localhost:8091' } })).status, 404);
  assert.equal((await get('/api/auth/status')).status, 200);
  const media = { origin: 'http://localhost:8091', async read(path: string) { const result = await get(path, { headers: { origin: 'http://localhost:8091', cookie: 'secret=x' } }); return new Response(result.body, { status: result.status, headers: { 'content-type': String(result.headers['content-type'] ?? '') } }); } };
  assert.deepEqual(await loadAppearance(media, () => true), { companionName: 'Mica', userName: '', companionAvatar: true, backgrounds: true });
  for (const kind of ['companionAvatar', 'landscape', 'portrait'] as const) assert.equal((await loadAppearanceImage(media, kind, () => true))?.bytes.length, 20);
  for (const path of ['/api/avatars/user', '/api/background-settings', '/api/backgrounds/portrait?x=1', '/api/avatars/companion/extra']) assert.equal((await get(path)).status, 404);
  for (const path of ['/api/chat/appearance', '/api/avatars/companion', '/api/backgrounds/landscape', '/api/backgrounds/portrait']) assert.equal((await get(path, { method: 'POST', headers: { origin: 'http://localhost:8091' } })).status, 404);

  for (const host of ['localhost:8091', '127.0.0.1:8091']) {
    assert.equal((await get('/api/chat/media/picture/preview', { headers: { host, origin: `http://${host}` } })).status, 200);
  }
  assert.equal((await get('/api/chat/media/picture/preview', { headers: { host: '192.168.50.2:8091', origin: 'http://192.168.50.2:8091' } })).status, 200);
  assert.equal((await get('/api/chat/media/picture/preview', { headers: { host: '192.168.50.3:8091' } })).status, 403);
  assert.equal((await get('/api/chat/media/picture/preview', { headers: { host: 'localhost:5903' } })).status, 403);
  for (const host of ['localhost:8081', '127.0.0.1:8081', 'localhost:8082', 'localhost:8092', '192.168.50.2:8081']) {
    assert.equal((await get('/api/chat/media/picture/preview', { headers: { host, origin: `http://${host}` } })).status, 403);
  }
  assert.equal((await get('/api/chat/media/picture/preview', { headers: { host: '192.168.50.2:8091', origin: 'http://localhost:8091' } })).status, 403);
  assert.throws(() => createSeedProxy({ seedRequest: request, metroRequest: request, lanHost: 'example.com' }));
  assert.equal((await get('/api/chat/media/picture/preview', { headers: { origin: 'http://evil.example' } })).status, 403);
  assert.equal((await get('/api/chat/media/picture/preview', { headers: { host: 'evil.example:8091' } })).status, 403);
  assert.equal((await get('/api/chat/media/picture/preview', { headers: { 'sec-fetch-site': 'cross-site' } })).status, 403);
  assert.equal((await get('/api/auth/sign-out', { method: 'POST', headers: { origin: 'http://localhost:8091' } })).status, 404);
  assert.equal((await get('/api/chat/images')).status, 404);
  const ws = new WebSocket(`ws://127.0.0.1:${port}/api/chat/socket`, { headers: { Host: 'localhost:8091', Origin: 'http://localhost:8091', Cookie: 'secret=x', Authorization: 'Bearer secret' } });
  let view: ChatView | undefined;
  const client = await openChat(ws as unknown as globalThis.WebSocket, value => { view = value; }, () => {});
  assert.equal(view?.sessionId, initial.sessionId);
  assert.equal((await client.history('cursor')).messages[0]?.text, '合成历史');
  const operationId = '00000000-0000-4000-8000-000000000001';
  assert.equal((await client.submit({ operationId, text: '合成发送' })).messageId, 'synthetic-message');
  assert.equal((await client.lookup(operationId))?.state, 'submitted'); assert.equal(submissions, 1);
  await new Promise(resolve => setTimeout(resolve, 30)); assert.equal(view?.streamingReply?.text, '合成回复');
  assert.ok(seen.every(h => !h.cookie && !h.authorization && !h.forwarded && !h['x-forwarded-host']));
  assert.ok(seen.some(h => h.host === '192.168.50.2:8091' && h.origin === 'http://192.168.50.2:8091'));
  client.close();
  const evil = new WebSocket(`ws://127.0.0.1:${port}/api/chat/socket`, { headers: { Host: 'localhost:8091', Origin: 'http://evil.example' } });
  const [error] = await once(evil, 'error'); assert.match(String(error), /403/);
});

test('synthetic client selection requires dev mode, explicit flag and exact local origin', async () => {
  const { isDevelopmentSeedAllowed } = await import('../src/cfl/seed-guard');
  assert.equal(isDevelopmentSeedAllowed(true, '1', 'http://localhost:8091'), true);
  assert.equal(isDevelopmentSeedAllowed(true, '1', 'http://127.0.0.1:8091'), true);
  for (const args of [[false, '1', 'http://localhost:8091'], [true, undefined, 'http://localhost:8091'], [true, '1', 'https://localhost:8091'], [true, '1', 'http://localhost:8081'], [true, '1', 'http://127.0.0.1:8081'], [true, '1', 'http://localhost:8092'], [true, '1', 'http://localhost:3090'], [true, '1', 'http://localhost:5904'], [true, '1', 'https://localhost:5903'], [true, '1', 'http://evil.example:8091'], [true, '1', undefined]] as const) assert.equal(isDevelopmentSeedAllowed(args[0], args[1], args[2]), false);
});


test('LAN seed requires exactly one opted-in private IPv4 address', async () => {
  const { isDevelopmentSeedAllowed } = await import('../src/cfl/seed-guard');
  const { isPrivateIPv4 } = await import('../src/cfl/seed-address');
  for (const host of ['192.168.50.2', '10.1.2.3', '172.16.1.2', '172.31.255.255']) {
    assert.equal(isPrivateIPv4(host), true);
    assert.equal(isDevelopmentSeedAllowed(true, '1', `http://${host}:8091`, host), true);
    assert.equal(isDevelopmentSeedAllowed(false, '1', `http://${host}:8091`, host), false);
    assert.equal(isDevelopmentSeedAllowed(true, '1', `http://${host}:8091`), false);
    assert.equal(isDevelopmentSeedAllowed(true, '1', `http://${host}:8092`, host), false);
    assert.equal(isDevelopmentSeedAllowed(true, '1', `http://${host}:8081`, host), false);
  }
  for (const host of ['192.168.01.2', '192.168.1.256', '172.15.0.1', '172.32.0.1', '127.0.0.1', '8.8.8.8', 'example.com', '10.1.2.3:8091']) assert.equal(isPrivateIPv4(host), false);
  assert.equal(isDevelopmentSeedAllowed(true, '1', 'http://192.168.50.3:8091', '192.168.50.2'), false);
});

test('synthetic UUID uses secure random bytes and sets version and variant', async () => {
  const { syntheticOperationId } = await import('../src/cfl/seed-uuid');
  const random = { getRandomValues<T extends ArrayBufferView | null>(value: T): T {
    assert.ok(value instanceof Uint8Array); value.fill(255); return value;
  } };
  assert.equal(syntheticOperationId(random), 'ffffffff-ffff-4fff-bfff-ffffffffffff');
  assert.throws(() => syntheticOperationId({ getRandomValues() { throw Error('secure random unavailable'); } }), /secure random unavailable/);
});


test('LAN access is disabled unless explicitly configured', async t => {
  const unexpected = async () => { throw new Error('upstream must not be called'); };
  const proxy: http.Server = createSeedProxy({ seedRequest: unexpected, metroRequest: unexpected });
  proxy.listen(0, '127.0.0.1'); await once(proxy, 'listening');
  t.after(() => { proxy.closeAllConnections(); proxy.close(); });
  const port = (proxy.address() as { port: number }).port;
  const status = await new Promise<number>((resolve, reject) => {
    http.get({ host: '127.0.0.1', port, path: '/', headers: { host: '192.168.50.2:8091', origin: 'http://192.168.50.2:8091' } }, res => { res.resume(); resolve(res.statusCode!); }).on('error', reject);
  });
  assert.equal(status, 403);
});

test('seed proxy forwards only required attachment routes with same-origin and no credentials', async t => {
  const seen: { method?: string; url?: string; headers: http.IncomingHttpHeaders; body: string }[] = [];
  const fake = http.createServer((req, res) => { let body = ''; req.on('data', c => { body += c; }); req.on('end', () => { seen.push({ method: req.method, url: req.url, headers: req.headers, body }); res.writeHead(200, { 'content-type': 'application/json' }).end('{}'); }); });
  fake.listen(0, '127.0.0.1'); await once(fake, 'listening'); const fakePort = (fake.address() as {port: number}).port;
  const forward = async (options: RequestOptions) => http.request({ ...options, hostname: '127.0.0.1', port: fakePort });
  const proxy: http.Server = createSeedProxy({ seedRequest: forward, metroRequest: forward }); proxy.listen(0, '127.0.0.1'); await once(proxy, 'listening');
  t.after(() => { proxy.closeAllConnections(); proxy.close(); fake.closeAllConnections(); fake.close(); });
  const port = (proxy.address() as {port: number}).port;
  const request = (method: string, path: string, origin = 'http://localhost:8091') => new Promise<number>((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, path, method, headers: { host: 'localhost:8091', ...(origin ? { origin } : {}), cookie: 'secret=x', authorization: 'Bearer secret', 'content-type': 'application/json', ...(method === 'GET' ? {} : { 'content-length': '2' }) } }, res => { res.resume(); res.on('end', () => resolve(res.statusCode!)); }); req.on('error', error => reject(new Error(`${method} ${path}: ${error.message}`))); req.end(method === 'GET' ? undefined : '{}');
  });
  const id = '00000000-0000-4000-8000-000000000001';
  for (const [method, path] of [['POST','/api/chat/images'], ['POST','/api/chat/file-operations'], ['PUT',`/api/chat/file-operations/${id}/files/doc`], ['POST',`/api/chat/file-operations/${id}/complete`], ['POST','/api/stickers/stage'], ['POST','/api/stickers/favorites'], ['POST','/api/stickers/favorites/image'], ['GET','/api/stickers/packs?sessionId=s&limit=30'], ['GET',`/api/stickers/media/${'a'.repeat(64)}/thumbnail`]]) assert.equal(await request(method, path), 200, path);
  for (const [method, path] of [['POST','/api/auth/sign-out'], ['POST','/api/stickers/favorites?x=1'], ['POST','/api/stickers/favorites/upload'], ['POST','/api/stickers/favorites/image/extra'], ['PUT','/api/stickers/favorites'], ['DELETE','/api/stickers/favorites'], ['DELETE','/api/chat/images'], ['GET','/api/stickers/packs?sessionId=s&limit=30&unknown=1'], ['PUT','/api/chat/file-operations/------------------------------------/files/doc']]) assert.equal(await request(method, path), 404, path);
  assert.equal(await request('POST', '/api/chat/images', ''), 404);
  assert.equal(await request('POST', '/api/chat/images', 'http://evil.example'), 403);
  assert.equal(await request('POST', '/api/stickers/favorites', ''), 404);
  assert.equal(await request('POST', '/api/stickers/favorites/image', 'http://evil.example'), 403);
  assert.ok(seen.every(x => !x.headers.cookie && !x.headers.authorization)); assert.equal(seen.length, 9);
});

test('seed proxy permits validators and location-free 304 only for exact sticker media GET', async t => {
  const seen: { url?: string; headers: http.IncomingHttpHeaders }[] = [];
  let status = 304; let location: string | undefined;
  const fake = http.createServer((req, res) => {
    seen.push({ url: req.url, headers: req.headers });
    res.setHeader('ETag', '"synthetic-version"');
    res.setHeader('Cache-Control', 'private, no-cache');
    res.setHeader('Set-Cookie', 'secret=discard');
    res.setHeader('Access-Control-Allow-Origin', '*');
    if (location !== undefined) res.setHeader('Location', location);
    res.writeHead(status).end();
  });
  fake.listen(0, '127.0.0.1'); await once(fake, 'listening');
  const forward = async (options: RequestOptions) => http.request({ ...options, hostname: '127.0.0.1', port: (fake.address() as { port: number }).port });
  const proxy: http.Server = createSeedProxy({ seedRequest: forward, metroRequest: forward });
  proxy.listen(0, '127.0.0.1'); await once(proxy, 'listening');
  t.after(() => { proxy.closeAllConnections(); proxy.close(); fake.closeAllConnections(); fake.close(); });
  const port = (proxy.address() as { port: number }).port;
  const get = (path: string, headers: Record<string, string> = {}, method = 'GET') => new Promise<{ status: number; headers: http.IncomingHttpHeaders }>((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, method, path, headers: { host: 'localhost:8091', origin: 'http://localhost:8091', ...headers } }, res => { res.resume(); res.on('end', () => resolve({ status: res.statusCode!, headers: res.headers })); });
    req.on('error', reject); req.end();
  });
  const base = `/api/stickers/media/${'a'.repeat(64)}`;
  const conditional = { 'if-none-match': '"synthetic-version"', cookie: 'secret=x', authorization: 'Bearer secret', 'x-forwarded-host': 'untrusted' };
  for (const variant of ['thumbnail', 'original']) {
    const response = await get(`${base}/${variant}`, conditional);
    assert.equal(response.status, 304);
    assert.equal(response.headers.etag, '"synthetic-version"');
    assert.equal(response.headers['cache-control'], 'private, no-cache');
    assert.equal(response.headers['set-cookie'], undefined);
    assert.equal(response.headers['access-control-allow-origin'], undefined);
    assert.equal(seen.at(-1)?.headers['if-none-match'], conditional['if-none-match']);
  }
  for (const path of ['/api/auth/status', '/api/chat/files/picture']) {
    assert.equal((await get(path, conditional)).status, 502);
    assert.equal(seen.at(-1)?.headers['if-none-match'], undefined);
  }
  const count = seen.length;
  for (const [method, path] of [['GET', `${base}/thumbnail?x=1`], ['GET', `${base}/thumbnail/extra`], ['GET', `${base}/preview`], ['GET', `/api/stickers/media/${'A'.repeat(64)}/thumbnail`], ['POST', `${base}/thumbnail`]]) assert.equal((await get(path, conditional, method)).status, 404);
  assert.equal((await get(`${base}/thumbnail`, { ...conditional, origin: 'http://evil.example' })).status, 403);
  assert.equal((await get(`${base}/thumbnail`, { ...conditional, 'sec-fetch-site': 'cross-site' })).status, 403);
  assert.equal(seen.length, count);
  assert.equal((await get(`${base}/thumbnail`)).status, 502);
  for (const invalidLocation of ['https://elsewhere.invalid/', '']) {
    location = invalidLocation;
    assert.equal((await get(`${base}/thumbnail`, conditional)).status, 502);
  }
  location = undefined;
  for (const redirect of [300, 301, 302, 303, 305, 307, 308]) {
    status = redirect;
    assert.equal((await get(`${base}/thumbnail`, conditional)).status, 502);
  }
  for (const error of [401, 403, 404, 500]) {
    status = error;
    assert.equal((await get(`${base}/thumbnail`, conditional)).status, error);
  }
  assert.ok(seen.every(({ headers }) => !headers.cookie && !headers.authorization && !headers['x-forwarded-host']));
});

test('seed proxy limits conditional chat image responses to existing exact GET routes', async t => {
  const seen: { url?: string; headers: http.IncomingHttpHeaders }[] = [];
  let status = 304; let location: string | undefined;
  const fake = http.createServer((req, res) => {
    seen.push({ url: req.url, headers: req.headers });
    res.setHeader('ETag', '"image-v1"'); res.setHeader('Cache-Control', 'private, no-cache');
    res.setHeader('Set-Cookie', 'secret=discard'); res.setHeader('Access-Control-Allow-Origin', '*');
    if (location !== undefined) res.setHeader('Location', location);
    res.writeHead(status).end();
  });
  fake.listen(0, '127.0.0.1'); await once(fake, 'listening');
  const forward = async (options: RequestOptions) => http.request({ ...options, hostname: '127.0.0.1', port: (fake.address() as { port: number }).port });
  const proxy: http.Server = createSeedProxy({ seedRequest: forward, metroRequest: forward });
  proxy.listen(0, '127.0.0.1'); await once(proxy, 'listening');
  t.after(() => { proxy.closeAllConnections(); proxy.close(); fake.closeAllConnections(); fake.close(); });
  const port = (proxy.address() as { port: number }).port;
  const request = (path: string, headers: Record<string, string> = {}, method = 'GET') => new Promise<{ status: number; headers: http.IncomingHttpHeaders }>((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port, method, path, headers: { host: 'localhost:8091', origin: 'http://localhost:8091', ...headers } }, res => { res.resume(); res.on('end', () => resolve({ status: res.statusCode!, headers: res.headers })); });
    req.on('error', reject); req.end();
  });
  const base = '/api/chat/media/image_123-x';
  const conditional = { 'if-none-match': '"image-v1"', cookie: 'secret=x', authorization: 'Bearer secret', forwarded: 'host=other', 'x-forwarded-host': 'other' };
  for (const variant of ['preview', 'original']) {
    const response = await request(`${base}/${variant}`, conditional);
    assert.equal(response.status, 304); assert.equal(response.headers.etag, '"image-v1"');
    assert.equal(response.headers['cache-control'], 'private, no-cache');
    assert.equal(response.headers['set-cookie'], undefined); assert.equal(response.headers['access-control-allow-origin'], undefined);
    assert.equal(seen.at(-1)?.headers['if-none-match'], conditional['if-none-match']);
  }
  for (const path of ['/api/auth/status', '/api/chat/files/image_123-x', '/api/avatars/companion']) {
    assert.equal((await request(path, conditional)).status, 502);
    assert.equal(seen.at(-1)?.headers['if-none-match'], undefined);
  }
  const count = seen.length;
  for (const [method, path] of [['GET', `${base}/model`], ['GET', `${base}/preview?x=1`], ['GET', `${base}/preview/extra`], ['GET', '/api/chat/media//preview'], ['GET', `/api/chat/media/${'x'.repeat(101)}/preview`], ['GET', '/api/chat/media/bad%2Fid/preview'], ['POST', `${base}/preview`]]) assert.equal((await request(path, conditional, method)).status, 404, `${method} ${path}`);
  assert.equal((await request(`${base}/preview`, { ...conditional, host: 'evil.example:8091' })).status, 403);
  assert.equal((await request(`${base}/preview`, { ...conditional, origin: 'http://evil.example' })).status, 403);
  assert.equal((await request(`${base}/preview`, { ...conditional, 'sec-fetch-site': 'cross-site' })).status, 403);
  assert.equal(seen.length, count);
  assert.equal((await request(`${base}/preview`)).status, 502);
  assert.equal((await request(`${base}/original`, { 'if-none-match': '' })).status, 502);
  for (const invalidLocation of ['https://elsewhere.invalid/', '']) {
    location = invalidLocation; assert.equal((await request(`${base}/preview`, conditional)).status, 502);
  }
  location = undefined;
  for (const redirect of [300, 301, 302, 303, 305, 307, 308]) {
    status = redirect; assert.equal((await request(`${base}/preview`, conditional)).status, 502);
  }
  for (const result of [200, 401, 403, 404, 500]) {
    status = result; assert.equal((await request(`${base}/original`, conditional)).status, result);
  }
  assert.ok(seen.every(({ headers }) => !headers.cookie && !headers.authorization && !headers.forwarded && !headers['x-forwarded-host']));
});

test('test-owned HTTP seed proxy stages a file and sticker for a fixture chat without replay', async t => {
  const { createFixture } = await import('./fixtures/fixture');
  const { createFixtureMedia } = await import('./fixtures/fixture-attachments');
  const { StickerClient } = await import('../src/cfl/stickers');
  const { uploadFiles } = await import('../src/cfl/uploads');
  const backend = createFixtureMedia(); const calls: string[] = [];
  const fake = http.createServer((req, res) => {
    const chunks: Buffer[] = []; req.on('data', value => chunks.push(value)); req.on('end', () => { void (async () => {
      const method = req.method ?? 'GET', path = req.url ?? '/'; calls.push(`${method} ${path}`);
      const body = Buffer.concat(chunks); const input = method === 'PUT' ? new Blob([body]) : body.toString();
      const response = await backend.request(path, { method, ...(method === 'GET' ? {} : { body: input }) });
      const content = Buffer.from(await response.arrayBuffer()); res.writeHead(response.status, { 'content-type': response.headers.get('content-type') ?? 'application/octet-stream' }); res.end(content);
    })().catch(() => res.writeHead(500).end()); });
  });
  fake.listen(0, '127.0.0.1'); await once(fake, 'listening'); const fakePort = (fake.address() as { port: number }).port;
  const forward = async (options: RequestOptions) => http.request({ ...options, hostname: '127.0.0.1', port: fakePort });
  const proxy: http.Server = createSeedProxy({ seedRequest: forward, metroRequest: forward }); proxy.listen(0, '127.0.0.1'); await once(proxy, 'listening');
  t.after(() => { proxy.closeAllConnections(); proxy.close(); fake.closeAllConnections(); fake.close(); });
  const port = (proxy.address() as { port: number }).port;
  const request = async (path: string, init: RequestInit = {}): Promise<Response> => {
    const method = init.method ?? 'GET'; const input = init.body instanceof Blob ? Buffer.from(await init.body.arrayBuffer()) : Buffer.from(String(init.body ?? ''));
    return new Promise((resolve, reject) => {
      const req = http.request({ host: '127.0.0.1', port, path, method, headers: { host: 'localhost:8091', origin: 'http://localhost:8091', ...(method === 'GET' ? {} : { 'content-length': String(input.length) }), ...Object.fromEntries(new Headers(init.headers)) } }, res => {
        const chunks: Buffer[] = []; res.on('data', b => chunks.push(b)); res.on('end', () => resolve(new Response(res.statusCode === 204 ? null : Buffer.concat(chunks), { status: res.statusCode, headers: { 'content-type': String(res.headers['content-type'] ?? '') } })));
      }); req.on('error', reject); req.end(method === 'GET' ? undefined : input);
    });
  };
  const media = { origin: 'http://localhost:8091', request, read: (path: string) => request(path) };
  const { controller } = createFixture(); await controller.start();
  const body = new Blob(['synthetic'], { type: 'text/plain' });
  const op = await controller.sendPrepared('file', async c => ({ files: await uploadFiles(media, c.sessionId, c.operationId, [{ id: 'doc', kind: 'file', name: 'doc.txt', mediaType: body.type, size: body.size, body, uri: 'fixture://doc', release() {} }], c.view.capabilities.files || (() => { throw Error('missing capability'); })(), c.isCurrent, c.signal) }));
  assert.equal(controller.snapshot().view!.messages.find(m => m.operationId === op)?.files?.[0].name, 'doc.txt');
  const stickerClient = new StickerClient(media, 'fixture-session', controller.scope()); const page = await stickerClient.page('favorites'); assert.ok('stickers' in page);
  const sticker = page.stickers[0]; const stickerOp = await controller.sendPrepared('', async c => ({ images: [await new StickerClient(media, c.sessionId, c.isCurrent, c.signal).stage(c.operationId, sticker)] }));
  assert.equal(controller.snapshot().view!.messages.find(m => m.operationId === stickerOp)?.images?.[0].sticker?.id, sticker.id);
  assert.equal(calls.filter(x => x === 'POST /api/chat/file-operations').length, 1); assert.equal(calls.filter(x => x === 'POST /api/stickers/stage').length, 1); controller.stop();
});

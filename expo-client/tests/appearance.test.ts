import { test } from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { once } from 'node:events';
import { loadAppearance, loadAppearanceImage } from '../src/cfl/appearance';
import { nativeTransport, type MediaTransport } from '../src/cfl/transport';
import type { NativeAuth } from '../src/cfl/native-auth';

const metadata = { companionName: 'Mica', userName: '', companionAvatar: '/api/avatars/companion', backgrounds: { landscape: '/api/backgrounds/landscape', portrait: '/api/backgrounds/portrait' } };
const ok = () => true;

test('synthetic HTTP host: appearance, avatar and both backgrounds use native bearer, origin and no redirect', async t => {
  const seen: { path?: string; auth?: string; origin?: string }[] = [];
  const fake = http.createServer((req, res) => {
    seen.push({ path: req.url, auth: req.headers.authorization, origin: req.headers.origin });
    if (req.url === '/api/chat/appearance') { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(metadata)); }
    else if (req.url === '/api/avatars/companion' || req.url === '/api/backgrounds/landscape' || req.url === '/api/backgrounds/portrait') { res.writeHead(200, { 'Content-Type': 'image/webp' }); res.end('synthetic-image'); }
    else if (req.url === '/api/redirect') { res.writeHead(302, { Location: '/api/leak' }); res.end(); }
    else { res.writeHead(404); res.end(); }
  });
  fake.listen(0, '127.0.0.1'); await once(fake, 'listening');
  t.after(() => { fake.closeAllConnections(); fake.close(); });
  const port = (fake.address() as { port: number }).port;
  const origin = 'https://synthetic.invalid';
  const auth = { async tokenFor(value: string) { assert.equal(value, origin); return 'test-owned-token'; } } as unknown as NativeAuth;
  const transport = nativeTransport(origin, auth, async (input, init) => {
    const url = new URL(String(input)); assert.equal(url.origin, origin); assert.equal(init?.redirect, 'error');
    return fetch(`http://127.0.0.1:${port}${url.pathname}`, init);
  });
  assert.deepEqual(await loadAppearance(transport, ok), { companionName: 'Mica', userName: '', companionAvatar: true, backgrounds: true });
  for (const kind of ['companionAvatar', 'landscape', 'portrait'] as const) {
    const image = await loadAppearanceImage(transport, kind, ok);
    assert.equal(image?.contentType, 'image/webp'); assert.equal(new TextDecoder().decode(image?.bytes), 'synthetic-image');
  }
  assert.deepEqual(seen.map(x => x.path), ['/api/chat/appearance', '/api/avatars/companion', '/api/backgrounds/landscape', '/api/backgrounds/portrait']);
  assert.ok(seen.every(x => x.auth === 'Bearer test-owned-token' && x.origin === origin));
  await assert.rejects(transport.read('/api/redirect')); assert.equal(seen.some(x => x.path === '/api/leak'), false);
  await assert.rejects(transport.read('https://other.invalid/api/avatars/companion'), /invalid_media/);
});

test('missing appearance and images return null; denied, malformed and untrusted paths fail safely', async () => {
  const make = (response: () => Response): MediaTransport => ({ origin: 'fixture', async read() { return response(); } });
  const missing = make(() => new Response(null, { status: 404 }));
  assert.equal(await loadAppearance(missing, ok), null); assert.equal(await loadAppearanceImage(missing, 'portrait', ok), null);
  await assert.rejects(loadAppearance(make(() => new Response(null, { status: 403 })), ok), /access_denied/);
  await assert.rejects(loadAppearanceImage(make(() => new Response('x', { headers: { 'Content-Type': 'text/html' } })), 'companionAvatar', ok), /invalid_media/);
  const json = (value: unknown) => make(() => new Response(JSON.stringify(value), { headers: { 'Content-Type': 'application/json' } }));
  await assert.rejects(loadAppearance(json({ ...metadata, companionAvatar: '/api/private' }), ok), /invalid_appearance/);
  await assert.rejects(loadAppearance(json({ ...metadata, backgrounds: { ...metadata.backgrounds, portrait: 'https://other.invalid/image' } }), ok), /invalid_appearance/);
  await assert.rejects(loadAppearanceImage(missing, '../api/auth' as 'portrait', ok), /invalid_media/);
  await assert.rejects(loadAppearance(json({ ...metadata, companionName: 'x'.repeat(65536) }), ok), /invalid_appearance/);
});

test('bounded image reads reject excessive declared or streamed data and discard stale sessions', async () => {
  let active = true; let cancelled = false;
  const huge: MediaTransport = { origin: 'fixture', async read() { return new Response('x', { headers: { 'Content-Type': 'image/png', 'Content-Length': String(5 * 1024 * 1024 + 1) } }); } };
  await assert.rejects(loadAppearanceImage(huge, 'companionAvatar', ok), /invalid_media/);
  let chunks = 0;
  const streamed: MediaTransport = { origin: 'fixture', async read() { return new Response(new ReadableStream({ pull(controller) { chunks++; controller.enqueue(new Uint8Array(1024 * 1024)); }, cancel() { cancelled = true; } }), { headers: { 'Content-Type': 'image/png' } }); } };
  await assert.rejects(loadAppearanceImage(streamed, 'companionAvatar', ok), /invalid_media/); assert.ok(chunks <= 7); assert.equal(cancelled, true);
  let finish!: (value: Response) => void;
  const delayed: MediaTransport = { origin: 'fixture', async read() { return new Promise(resolve => { finish = resolve; }); } };
  const pending = loadAppearanceImage(delayed, 'portrait', () => active); active = false;
  finish(new Response('x', { headers: { 'Content-Type': 'image/png' } })); await assert.rejects(pending, /session_changed/);
  active = true; const pendingAppearance = loadAppearance(delayed, () => active); active = false;
  finish(new Response(JSON.stringify(metadata), { headers: { 'Content-Type': 'application/json' } })); await assert.rejects(pendingAppearance, /session_changed/);
  let invalidate!: () => void;
  const chunked: MediaTransport = { origin: 'fixture', async read() { return new Response(new ReadableStream({ start(controller) { invalidate = () => { active = false; controller.enqueue(new Uint8Array([1])); }; } }), { headers: { 'Content-Type': 'image/png' } }); } };
  active = true; const waiting = loadAppearanceImage(chunked, 'portrait', () => active); await Promise.resolve(); await Promise.resolve(); invalidate(); await assert.rejects(waiting, /session_changed/);
});

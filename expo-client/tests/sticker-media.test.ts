import { test } from 'node:test';
import assert from 'node:assert/strict';
import { StickerClient } from '../src/cfl/stickers';
import { webTransport, type ApiTransport } from '../src/cfl/transport';

const version = 'a'.repeat(64);

test('web sticker media uses browser cache policy with same-origin credentials and no redirects', async t => {
  const previous = Object.getOwnPropertyDescriptor(globalThis, 'window');
  t.after(() => { if (previous) Object.defineProperty(globalThis, 'window', previous); else Reflect.deleteProperty(globalThis, 'window'); });
  Object.defineProperty(globalThis, 'window', { configurable: true, value: { location: { origin: 'https://fixture.invalid' } } });
  let request: { url: string; init?: RequestInit } | undefined;
  t.mock.method(globalThis, 'fetch', async (url: string | URL | Request, init?: RequestInit) => {
    request = { url: String(url), init }; return new Response(new Uint8Array([1, 2]), { headers: { 'content-type': 'image/webp' } });
  });
  const abort = new AbortController();
  const data = await new StickerClient(webTransport('https://fixture.invalid'), 'A', () => true, abort.signal).media(version);
  assert.deepEqual(data, { bytes: new Uint8Array([1, 2]), contentType: 'image/webp' });
  assert.equal(request?.url, `https://fixture.invalid/api/stickers/media/${version}/thumbnail`);
  assert.equal(request?.init?.cache, undefined);
  assert.equal(request?.init?.signal, abort.signal);
  assert.equal(request?.init?.credentials, 'same-origin');
  assert.equal(request?.init?.redirect, 'error');
});

test('sticker media rejects denied, invalid and late responses without cached fallback', async () => {
  let response = () => new Response(new Uint8Array([1]), { headers: { 'content-type': 'image/webp' } });
  let current = true;
  const transport: ApiTransport = { origin: 'https://fixture.invalid', async read() { throw Error('unused'); }, async request() { return response(); } };
  const client = new StickerClient(transport, 'A', () => current);
  assert.ok(await client.media(version));
  for (const status of [401, 403]) {
    response = () => new Response(null, { status });
    await assert.rejects(client.media(version), /access_denied/);
  }
  response = () => new Response(null, { status: 404 }); assert.equal(await client.media(version), null);
  response = () => new Response(null, { status: 304 }); await assert.rejects(client.media(version), /sticker_unavailable/);
  response = () => new Response(new Uint8Array([1]), { headers: { 'content-type': 'image/png' } });
  await assert.rejects(client.media(version), /invalid_media/);
  response = () => new Response(new Uint8Array(160_001), { headers: { 'content-type': 'image/webp' } });
  await assert.rejects(client.media(version), /invalid_media/);
  let resolve!: (value: Response) => void;
  transport.request = async () => new Promise<Response>(done => { resolve = done; });
  const late = client.media(version); current = false;
  resolve(new Response(new Uint8Array([1]), { headers: { 'content-type': 'image/webp' } }));
  await assert.rejects(late, /session_changed/);
  const controller = new AbortController(); controller.abort(); current = true;
  await assert.rejects(new StickerClient(transport, 'A', () => current, controller.signal).media(version), { name: 'AbortError' });
});

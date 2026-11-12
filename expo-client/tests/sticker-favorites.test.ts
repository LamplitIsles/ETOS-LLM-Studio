import { test } from 'node:test';
import assert from 'node:assert/strict';
import { StickerClient } from '../src/cfl/stickers';
import { nativeTransport, webTransport, type ApiTransport } from '../src/cfl/transport';
import { createFixtureMedia } from './fixtures/fixture-attachments';
import type { ImageRef } from '../vendor/contracts/src/index';

const sample = { id: 'fixture-sticker', version: '0'.repeat(64), name: '小绿', tags: ['微笑'], mediaType: 'image/webp', available: true };
const image: ImageRef = { attachmentId: 'fixture-image', name: '湖边风景.png', mediaType: 'image/png', availability: 'available' };
const page = async (client: StickerClient) => {
  const result = await client.page('favorites');
  assert.ok('stickers' in result); return result.stickers;
};

test('favorites add, remove and favorite chat image using the CFL session contract', async () => {
  const media = createFixtureMedia();
  const calls: { path: string; body: unknown }[] = [];
  const transport: ApiTransport = { ...media, async request(path, init) { calls.push({ path, body: init?.body && JSON.parse(String(init.body)) }); return media.request(path, init); } };
  const client = new StickerClient(transport, 'fixture-session', () => true);
  assert.deepEqual((await page(client)).map(item => item.id), [sample.id]);
  assert.equal((await client.favorite(sample.id, false)).favorite, false);
  assert.deepEqual(await page(client), []);
  assert.equal((await client.favorite(sample.id, true)).sticker.id, sample.id);
  assert.deepEqual((await page(client)).map(item => item.id), [sample.id]);
  const saved = await client.favoriteImage(image);
  assert.equal(saved.favorite, true); assert.equal(saved.sticker.name, image.name);
  assert.equal((await client.media(saved.sticker.version, 'original'))?.contentType, 'image/png');
  assert.ok((await page(client)).some(item => item.id === saved.sticker.id));
  const first = await client.page('favorites', { limit: 1 }); assert.ok('stickers' in first && first.nextCursor);
  const second = await client.page('favorites', { limit: 1, cursor: first.nextCursor }); assert.ok('stickers' in second);
  assert.deepEqual([...first.stickers, ...second.stickers].map(item => item.id), [sample.id, saved.sticker.id]);
  assert.equal(second.nextCursor, null);
  await client.favorite(saved.sticker.id, false);
  assert.ok(!(await page(client)).some(item => item.id === saved.sticker.id));
  await client.favoriteImage({ ...image, sticker: { id: sample.id, version: sample.version } });
  assert.equal(calls.at(-1)?.path, '/api/stickers/favorites');
  assert.deepEqual(calls.at(-1)?.body, { sessionId: 'fixture-session', stickerId: sample.id, favorite: true });
  assert.deepEqual(calls.find(call => call.path === '/api/stickers/favorites/image')?.body, { sessionId: 'fixture-session', imageId: image.attachmentId, name: image.name, tags: [] });
  const count = calls.length;
  await assert.rejects(client.favoriteImage({ ...image, availability: 'missing' }), /invalid_sticker/);
  await assert.rejects(client.favorite('../invalid', true));
  assert.equal(calls.length, count);
});

test('favorite validates response shape, identity and status and does not replay failures', async () => {
  let result: unknown = { sticker: sample, favorite: true }, calls = 0, status = 200;
  const media: ApiTransport = { origin: 'synthetic', async read() { throw Error('unused'); }, async request() { calls++; return Response.json(result, { status }); } };
  const client = new StickerClient(media, 'fixture-session', () => true);
  for (const bad of [{ sticker: sample, favorite: true, extra: 1 }, { sticker: { ...sample, id: 'wrong' }, favorite: true }, { sticker: sample, favorite: false }, { sticker: { ...sample, unexpected: true }, favorite: true }]) {
    result = bad; await assert.rejects(client.favorite(sample.id, true));
  }
  result = { sticker: sample, favorite: true }; status = 401;
  await assert.rejects(client.favorite(sample.id, true), /access_denied/);
  status = 503; await assert.rejects(client.favorite(sample.id, true), /sticker_unavailable/);
  status = 200; result = { sticker: sample, favorite: false };
  await assert.rejects(client.favoriteImage(image), /invalid_sticker/);
  assert.equal(calls, 7);
});

test('late favorite completion is discarded on session A to B to A or abort and never automatically retried', async () => {
  let generation = 1, calls = 0, resolve!: (response: Response) => void;
  const media: ApiTransport = { origin: 'synthetic', async read() { throw Error('unused'); }, async request() { calls++; return new Promise<Response>(r => { resolve = r; }); } };
  const client = new StickerClient(media, 'A', () => generation === 1);
  const late = client.favorite(sample.id, true);
  generation++; generation++;
  resolve(Response.json({ sticker: sample, favorite: true }));
  await assert.rejects(late, /session_changed/); assert.equal(calls, 1);
  await assert.rejects(client.favorite(sample.id, true), /session_changed/); assert.equal(calls, 1);
  const abort = new AbortController();
  const aborted = new StickerClient(media, 'A', () => true, abort.signal);
  const pending = aborted.favorite(sample.id, false); abort.abort();
  resolve(Response.json({ sticker: sample, favorite: false }));
  await assert.rejects(pending, { name: 'AbortError' }); assert.equal(calls, 2);
  await assert.rejects(aborted.favorite(sample.id, false), { name: 'AbortError' }); assert.equal(calls, 2);
});

test('favorite response body arriving after disposal or cancellation is discarded', async () => {
  let current = true, calls = 0, finish!: () => void;
  const media: ApiTransport = { origin: 'synthetic', async read() { throw Error('unused'); }, async request() {
    calls++;
    return new Response(new ReadableStream({ start(stream) { finish = () => { stream.enqueue(new TextEncoder().encode(JSON.stringify({ sticker: sample, favorite: true }))); stream.close(); }; } }));
  } };
  const pending = new StickerClient(media, 'A', () => current).favorite(sample.id, true);
  await new Promise(resolve => setTimeout(resolve, 0)); current = false; finish();
  await assert.rejects(pending, /session_changed/);
  current = true;
  const abort = new AbortController();
  const cancelled = new StickerClient(media, 'A', () => current, abort.signal).favorite(sample.id, true);
  await new Promise(resolve => setTimeout(resolve, 0)); abort.abort(); finish();
  await assert.rejects(cancelled, { name: 'AbortError' }); assert.equal(calls, 2);
});

test('native favorite uses the configured HTTPS origin, bearer and no redirects', async () => {
  let request: { url: string; init?: RequestInit } | undefined;
  const transport = nativeTransport('https://fixture.invalid', { async tokenFor() { return 'synthetic-token'; } } as never, async (url, init) => {
    request = { url: String(url), init }; return Response.json({ sticker: sample, favorite: true });
  });
  await new StickerClient(transport, 'A', () => true).favorite(sample.id, true);
  assert.equal(request?.url, 'https://fixture.invalid/api/stickers/favorites');
  const headers = new Headers(request?.init?.headers);
  assert.equal(headers.get('authorization'), 'Bearer synthetic-token'); assert.equal(headers.get('origin'), 'https://fixture.invalid');
  assert.equal(request?.init?.redirect, 'error'); assert.equal(request?.init?.credentials, 'omit');
});

test('web favorite uses the existing HTTPS same-origin session without redirects', async t => {
  const previous = Object.getOwnPropertyDescriptor(globalThis, 'window');
  t.after(() => { if (previous) Object.defineProperty(globalThis, 'window', previous); else Reflect.deleteProperty(globalThis, 'window'); });
  Object.defineProperty(globalThis, 'window', { configurable: true, value: { location: { origin: 'https://fixture.invalid' } } });
  let request: { url: string; init?: RequestInit } | undefined;
  t.mock.method(globalThis, 'fetch', async (url: string | URL | Request, init?: RequestInit) => {
    request = { url: String(url), init }; return Response.json({ sticker: sample, favorite: false });
  });
  assert.throws(() => webTransport('https://other.invalid'), /same_origin_required/);
  await new StickerClient(webTransport('https://fixture.invalid'), 'A', () => true).favorite(sample.id, false);
  assert.equal(request?.url, 'https://fixture.invalid/api/stickers/favorites');
  assert.equal(request?.init?.credentials, 'same-origin'); assert.equal(request?.init?.redirect, 'error');
});

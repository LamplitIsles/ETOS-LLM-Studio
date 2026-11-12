import { test } from 'node:test';
import assert from 'node:assert/strict';
import { inflateSync } from 'node:zlib';
import { classifyMarkdownImage, loadMarkdownImage } from '../src/cfl/markdown-image';
import { loadImage, type ApiTransport } from '../src/cfl/transport';
import { scopedImageUri } from '../src/cfl/markdown-image-uri-core';
import { createMarkdownImageUri } from '../src/cfl/markdown-image-uri';
import { createFixture } from './fixtures/fixture';
import { fixtureWorkspaceImagePath, transparentStickerBase64 } from './fixtures/fixture-attachments';
import { workspaceImageUrl } from '../vendor/contracts/src/workspace-images';
import { hasMarkdownParser } from '../src/cfl/markdown-resolver-core';

test('native renderer availability requires the named parser and collect function', () => {
  assert.equal(hasMarkdownParser(name => { assert.equal(name, 'EnrichedMarkdownParser'); return { collect() {} }; }), true);
  assert.equal(hasMarkdownParser(() => null), false);
  assert.equal(hasMarkdownParser(() => ({ collect: 'not-a-function' })), false);
  assert.equal(hasMarkdownParser(() => { throw Error('module unavailable'); }), false);
});

test('workspace contract encodes original Markdown destination once and gates capability', async () => {
  const { media } = createFixture(); const calls: string[] = [];
  const transport: ApiTransport = { ...media, async request(path, init) { calls.push(path); return media.request(path, init); } };
  const options = { workspaceImages: true, isCurrent: () => true };
  const source = encodeURI(fixtureWorkspaceImagePath);
  assert.equal(workspaceImageUrl(source), `/api/chat/workspace-image?path=${encodeURIComponent(fixtureWorkspaceImagePath)}`);
  assert.equal((await loadMarkdownImage(source, transport, options)).contentType, 'image/png');
  assert.equal(calls[0], workspaceImageUrl(source));
  assert.equal((await loadMarkdownImage(calls[0], transport, options)).contentType, 'image/png');
  await assert.rejects(loadMarkdownImage(source, transport, { ...options, workspaceImages: false }), /invalid_media/);
  await assert.rejects(loadMarkdownImage(calls[0], transport, { ...options, workspaceImages: false }), /invalid_media/);
  for (const bad of ['broken%.png', 'file:///secret.png', '//evil/image.png', '/api/auth/status', '/api/chat/media/../secret/preview', '/api/chat/media/a/preview?x=1', '/api/chat/workspace-image?path=x.png&x=1']) await assert.rejects(loadMarkdownImage(bad, transport, options), /invalid_media/);
  assert.equal(calls.length, 2);
});

test('allowed authenticated API images and external fetch keep separate credentials', async () => {
  const paths: string[] = []; let external: { url: string; init?: RequestInit } | undefined;
  const image = () => new Response(new Uint8Array([1, 2]), { headers: { 'content-type': 'image/gif' } });
  const transport: ApiTransport = { origin: 'https://fixture.invalid', async read() { throw Error('unused'); }, async request(path) { paths.push(path); return image(); } };
  const options = { workspaceImages: false, isCurrent: () => true, externalFetch: async (input: string | URL | Request, init?: RequestInit) => { external = { url: String(input), init }; return image(); } };
  for (const path of [`/api/images/${'a'.repeat(64)}`, `/api/conversation-images/${'b'.repeat(64)}`, '/api/chat/media/id_1/original', `/api/stickers/media/${'c'.repeat(64)}/original`, '/api/avatars/companion', '/api/backgrounds/portrait']) assert.equal((await loadMarkdownImage(path, transport, options)).contentType, 'image/gif');
  const size = paths.length;
  assert.equal((await loadMarkdownImage('https://other.invalid/image.gif', transport, options)).bytes.length, 2);
  assert.equal(paths.length, size); assert.equal(external?.url, 'https://other.invalid/image.gif');
  assert.equal(external?.init?.credentials, 'omit'); assert.equal(external?.init?.redirect, 'error'); assert.equal(external?.init?.headers, undefined);
  await assert.rejects(loadMarkdownImage('https://user:secret@other.invalid/x.png', transport, options), /invalid_media/);
});

test('absolute CFL image URLs use the allowlisted authenticated path, never external fetch', async () => {
  const paths: string[] = [];
  const transport: ApiTransport = { origin: 'https://fixture.invalid', async read() { throw Error('unused'); }, async request(path) { paths.push(path); return new Response(new Uint8Array([1]), { headers: { 'content-type': 'image/png' } }); } };
  const options = { workspaceImages: true, isCurrent: () => true, externalFetch: async () => { throw Error('unexpected external request'); } };
  const workspace = workspaceImageUrl(encodeURI(fixtureWorkspaceImagePath))!;
  for (const path of ['/api/chat/media/id_1/original', workspace]) {
    await loadMarkdownImage(`https://fixture.invalid:443${path}`, transport, options);
    assert.equal(paths.at(-1), path);
  }
  for (const suffix of ['/api/auth/status', '/outside.png', '/api/chat/media/../avatars/user', '/api/chat/media/id_1/original?x=1', `${workspace}&extra=1`, '/api/avatars/user#', '/api/avatars/%75ser']) {
    await assert.rejects(loadMarkdownImage(`https://fixture.invalid${suffix}`, transport, options), /invalid_media/);
  }
  await assert.rejects(loadMarkdownImage(`https://fixture.invalid${workspace}`, transport, { ...options, workspaceImages: false }), /invalid_media/);
  assert.equal(paths.length, 2);
});

test('Web direct source is restricted to valid cross-origin HTTP(S), with scope and cancellation', () => {
  let current = true;
  const options = { workspaceImages: true, isCurrent: () => current };
  const classify = (source: string) => classifyMarkdownImage(source, 'https://fixture.invalid', options);
  assert.deepEqual(classify('https://elsewhere.invalid/image.png?size=large'), { kind: 'external', url: 'https://elsewhere.invalid/image.png?size=large' });
  assert.deepEqual(classify('http://elsewhere.invalid/image.gif'), { kind: 'external', url: 'http://elsewhere.invalid/image.gif' });
  assert.deepEqual(classify('https://fixture.invalid/api/avatars/user'), { kind: 'api', path: '/api/avatars/user' });
  for (const source of ['https://user:secret@elsewhere.invalid/x.png', 'https://@elsewhere.invalid/x.png', ' https://elsewhere.invalid/x.png', 'https://elsewhere.invalid/x y.png', 'https://elsewhere.invalid/x\n.png', 'https://elsewhere.invalid/%00.png', 'https://elsewhere.invalid/%C2%85.png', 'https://elsewhere.invalid/%zz.png', 'https://elsewhere.invalid\\@fixture.invalid/x.png', '//elsewhere.invalid/x.png', 'javascript:alert(1)', 'data:image/png,x']) assert.throws(() => classify(source), /invalid_media/);
  current = false;
  assert.throws(() => classify('https://elsewhere.invalid/image.png'), /session_changed/);
  const abort = new AbortController(); abort.abort();
  assert.throws(() => classifyMarkdownImage('https://elsewhere.invalid/image.png', 'https://fixture.invalid', { ...options, isCurrent: () => true, signal: abort.signal }), { name: 'AbortError' });
});

test('image responses obey size, MIME, authorization, redirect and session bounds', async () => {
  let response = () => new Response(new Uint8Array([1]), { headers: { 'content-type': 'image/png' } });
  let current = true;
  const transport: ApiTransport = { origin: 'fixture', async read() { throw Error('unused'); }, async request() { return response(); } };
  const options = { workspaceImages: true, isCurrent: () => current };
  for (const status of [401, 403]) { response = () => new Response(null, { status }); await assert.rejects(loadMarkdownImage('x.png', transport, options), /access_denied/); }
  response = () => new Response(null, { status: 404 }); await assert.rejects(loadMarkdownImage('x.png', transport, options), /missing/);
  response = () => new Response(new Uint8Array([1]), { headers: { 'content-type': 'image/svg+xml' } }); await assert.rejects(loadMarkdownImage('x.png', transport, options), /invalid_media/);
  response = () => new Response(new Uint8Array([1]), { headers: { 'content-type': 'image/png', 'content-length': String(20 * 1024 * 1024 + 1) } }); await assert.rejects(loadMarkdownImage('x.png', transport, options), /invalid_media/);
  response = () => { const result = new Response(new Uint8Array([1]), { headers: { 'content-type': 'image/png' } }); Object.defineProperty(result, 'redirected', { value: true }); return result; };
  await assert.rejects(loadMarkdownImage('x.png', transport, options), /unavailable/);
  let resolve!: (response: Response) => void;
  transport.request = async () => new Promise<Response>(done => { resolve = done; });
  const pending = loadMarkdownImage('x.png', transport, options); current = false;
  resolve(new Response(new Uint8Array([1]), { headers: { 'content-type': 'image/png' } }));
  await assert.rejects(pending, /session_changed/);
});

test('late streamed image bytes and aborted work cannot cross a session scope', async () => {
  let generation = 1, finish!: () => void;
  const transport: ApiTransport = { origin: 'fixture', async read() { throw Error('unused'); }, async request() {
    return new Response(new ReadableStream({ start(stream) { finish = () => { stream.enqueue(new Uint8Array([1])); stream.close(); }; } }), { headers: { 'content-type': 'image/png' } });
  } };
  const pending = loadMarkdownImage('x.png', transport, { workspaceImages: true, isCurrent: () => generation === 1 });
  await new Promise(resolve => setTimeout(resolve, 0)); generation = 3; finish();
  await assert.rejects(pending, /session_changed/);
  generation = 1;
  const abort = new AbortController();
  const cancelled = loadMarkdownImage('x.png', transport, { workspaceImages: true, isCurrent: () => generation === 1, signal: abort.signal });
  await new Promise(resolve => setTimeout(resolve, 0)); abort.abort(); finish();
  await assert.rejects(cancelled, { name: 'AbortError' });
});

test('scoped URI releases late resources and browser Blob URLs', async () => {
  let current = true, released = 0, complete!: () => void;
  const image = { bytes: new Uint8Array([1, 2]), contentType: 'image/png' };
  const late = scopedImageUri(image, () => current, undefined, { create: async () => { await new Promise<void>(done => { complete = done; }); return { uri: 'fixture://one', release() { released++; } }; } });
  current = false; complete(); await assert.rejects(late, /session_changed/); assert.equal(released, 1);
  current = true;
  const uri = await createMarkdownImageUri(image, () => current); assert.match(uri.uri, /^blob:/); uri.release(); uri.release();
  await assert.rejects(fetch(uri.uri));
});

test('ready agent sticker retains message attachment identity and original transparent bytes', async () => {
  const { controller, media } = createFixture(); await controller.start();
  const message = controller.snapshot().view!.messages.find(item => item.id === 'fixture-agent-sticker-message')!;
  assert.equal(message.imageState, 'ready'); assert.equal(message.images?.[0].sticker?.id, 'fixture-sticker');
  const image = await loadImage(media, message.images![0].attachmentId, controller.scope(), 'original');
  assert.equal(Buffer.from(image.bytes).toString('base64'), transparentStickerBase64);
  const png = Buffer.from(image.bytes); assert.equal(png[25], 6, 'PNG has an alpha channel');
  const raw = inflateSync(png.subarray(41, 41 + png.readUInt32BE(33)));
  const alpha = Array.from({ length: 256 }, (_, index) => raw[Math.floor(index / 16) * 65 + 1 + (index % 16) * 4 + 3]);
  assert.ok(alpha.includes(0) && alpha.includes(255), 'synthetic image has transparent and opaque pixels');
  assert.notDeepEqual((await loadImage(media, message.images![0].attachmentId, controller.scope())).bytes, image.bytes);
  controller.stop();
});

test('original sticker variant makes one original attachment request and preserves GIF bytes', async () => {
  const data = new Uint8Array([71, 73, 70, 56, 57, 97, 0, 1]); const calls: string[] = [];
  const media = { origin: 'fixture', async read(path: string) { calls.push(path); return new Response(data, { headers: { 'content-type': 'image/gif' } }); } };
  const image = await loadImage(media, 'snapshot-1', () => true, 'original');
  assert.deepEqual(calls, ['/api/chat/media/snapshot-1/original']); assert.equal(image.contentType, 'image/gif'); assert.deepEqual(image.bytes, data);
});

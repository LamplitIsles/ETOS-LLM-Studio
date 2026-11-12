import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createFixture } from './fixtures/fixture';
import { fixtureImageBase64 } from './fixtures/fixture-art';
import { StickerClient } from '../src/cfl/stickers';
import { uploadFiles, uploadImages } from '../src/cfl/uploads';
import { loadImage } from '../src/cfl/transport';
import { loadFile } from '../src/cfl/files';
import { ChatController, type ChatPort, type Pending, type PendingStore } from '../src/cfl/chat';
import type { AttachmentDraft } from '../src/cfl/drafts';
import type { ChatView } from '../vendor/contracts/src/index';

const draft = (kind: 'image' | 'file', body: Blob, id: string, name: string): AttachmentDraft => ({ id, kind, name, body, size: body.size, mediaType: body.type, uri: 'fixture://image', width: 100, height: 100, release() {} });
const bytes = Uint8Array.from(atob(fixtureImageBase64), c => c.charCodeAt(0));
const jpeg = async () => '/9j/2Q==';

test('fixture offers paged sticker packs/search/favorites, media and actual staged sticker submission', async () => {
  const { controller, media } = createFixture(); await controller.start();
  const client = new StickerClient(media, 'fixture-session', controller.scope());
  const packs = await client.page('packs'); assert.ok('packs' in packs); assert.equal(packs.packs[0].id, 'fixture-pack');
  const page = await client.page('pack', { packId: 'fixture-pack' }); assert.ok('stickers' in page); const sticker = page.stickers[0];
  const favorites = await client.page('favorites'); assert.ok('stickers' in favorites); assert.equal(favorites.stickers[0].id, sticker.id);
  const search = await client.page('search', { query: '小绿' }); assert.ok('stickers' in search); assert.equal(search.stickers.length, 1);
  assert.equal((await client.media(sticker.version))?.contentType, 'image/webp');
  const op = await controller.sendPrepared('', async c => ({ images: [await new StickerClient(media, c.sessionId, c.isCurrent).stage(c.operationId, sticker)] }));
  const sent = controller.snapshot().view!.messages.find(m => m.operationId === op)!;
  assert.equal(sent.images?.[0].sticker?.id, sticker.id); assert.equal((await loadImage(media, sent.images![0].attachmentId, controller.scope())).contentType, 'image/webp');
  controller.stop(); await assert.rejects(client.page('packs'), /session_changed/);
});

test('fixture stages image and file once and submits both using one operation', async () => {
  const { controller, media } = createFixture(); await controller.start();
  const image = draft('image', new Blob([bytes], { type: 'image/png' }), 'photo-1', 'drawing.png');
  const file = draft('file', new Blob(['synthetic'], { type: 'text/plain' }), 'file-1', 'hello.txt');
  let uploads = 0; const port = { ...media, async request(path: string, init?: RequestInit) { if (init?.method === 'POST' || init?.method === 'PUT') uploads++; return media.request(path, init); } };
  const op = await controller.sendPrepared('附上资料', async c => ({
    images: await uploadImages(port, c.sessionId, c.operationId, [image], c.view.capabilities.images || (() => { throw Error('no images'); })(), c.isCurrent, jpeg),
    files: await uploadFiles(port, c.sessionId, c.operationId, [file], c.view.capabilities.files || (() => { throw Error('no files'); })(), c.isCurrent),
  }));
  const sent = controller.snapshot().view!.messages.find(m => m.operationId === op)!;
  assert.equal(sent.images?.[0].name, 'drawing.png'); assert.equal(sent.files?.[0].name, 'hello.txt'); assert.equal(uploads, 4);
  assert.deepEqual((await loadImage(media, sent.images![0].attachmentId, controller.scope())).bytes, bytes);
  assert.equal(new TextDecoder().decode((await loadFile(media, sent.files![0], controller.scope()))!), 'synthetic');
  controller.stop();
});

test('preparation failure and session switch never dispatch, unknown submission retains references and never replays', async () => {
  let entries: Pending[] = [], sent = 0, changed!: (v: ChatView) => void;
  const ref = { attachmentId: 'f', name: 'note.txt', mediaType: 'text/plain', size: 4, availability: 'available' as const };
  const store: PendingStore = { async load() { return entries; }, async save(_, x) { entries = x; } };
  const view: ChatView = { version: 2, sessionId: 's', name: 'test', activeTurnId: null, contextUsage: { tokens: null, capacity: null }, compaction: null, messages: [], before: null, capabilities: { text: true, steer: true, stop: true, images: false } };
  const port: ChatPort = { async history() { return { messages: [], before: null }; }, async submit() { sent++; throw Error('lost'); }, async lookup() { return null; }, close() {} };
  const c = new ChatController('test', async () => ({ close() {} }) as WebSocket, store, () => '00000000-0000-4000-8000-000000000001', async (_, fn) => { changed = fn; fn(view); return port; });
  await c.start(); await assert.rejects(c.sendPrepared('', async () => { throw Error('prep'); }), /prep/); assert.equal(sent, 0); assert.equal(entries.length, 0);
  let finish!: () => void; let cancelled = false; const waiting = c.sendPrepared('', async ({ signal }) => { signal.addEventListener('abort', () => { cancelled = true; }); await new Promise<void>(r => { finish = r; }); return { files: [ref] }; });
  await Promise.resolve(); changed({ ...view, sessionId: 'other' }); assert.equal(cancelled, true); finish(); await assert.rejects(waiting, /session_changed/); assert.equal(sent, 0);
  changed(view); await c.sendPrepared('', async () => ({ files: [ref] })); assert.equal(sent, 1); assert.equal(entries[0].files?.[0].attachmentId, 'f');
  entries[0].createdAt = 0; await c.reconcile(); assert.equal(sent, 1); assert.equal(entries[0].state, 'unknown'); assert.deepEqual(entries[0].files, [ref]); c.stop();
});

test('draft validation enforces advertised counts, byte limits and session-local uniqueness', async () => {
  const { validateDrafts } = await import('../src/cfl/intake');
  const { controller } = createFixture(); await controller.start(); const view = controller.snapshot().view!;
  const d = draft('file', new Blob(['x']), 'id-1', 'a.txt'); validateDrafts(view, [d]);
  assert.throws(() => validateDrafts(view, [d, d]), /invalid_drafts/);
  assert.throws(() => validateDrafts({ ...view, capabilities: { ...view.capabilities, files: false } }, [d]), /files_unavailable/);
  assert.throws(() => validateDrafts({ ...view, capabilities: { ...view.capabilities, files: { maxFilesPerMessage: 1, maxFileBytes: 1, maxMessageFileBytes: 1 } } }, [d, { ...d, id: 'id-2' }]), /invalid_files/);
  controller.stop();
});

test('file download handles zero byte files and rejects wrong lengths', async () => {
  const ref = { attachmentId: 'empty', name: 'empty.txt', mediaType: 'text/plain', size: 0, availability: 'available' as const };
  const response = (data: string) => ({ origin: 'test', async read() { return new Response(data, { headers: { 'Content-Type': 'application/octet-stream' } }); } });
  assert.equal((await loadFile(response(''), ref, () => true))?.length, 0);
  await assert.rejects(loadFile(response('x'), ref, () => true), /invalid_file/);
  assert.equal(await loadFile(response(''), { ...ref, availability: 'missing' }, () => true), null);
});


test('native write transport pins origin, overwrites credential headers and refuses redirects', async () => {
  const { nativeTransport } = await import('../src/cfl/transport');
  let calls = 0; const origin = 'https://fixture.invalid';
  const transport = nativeTransport(origin, { async tokenFor() { return 'synthetic-token'; } } as never, async (input, init) => {
    calls++; assert.equal(String(input), `${origin}/api/chat/file-operations`); assert.equal(init?.redirect, 'error'); assert.equal(init?.credentials, 'omit');
    const headers = new Headers(init?.headers); assert.equal(headers.get('authorization'), 'Bearer synthetic-token'); assert.equal(headers.get('origin'), origin); return new Response('{}');
  });
  await transport.request('/api/chat/file-operations', { method: 'POST', headers: { Authorization: 'Bearer wrong', Origin: 'https://other.invalid' }, redirect: 'follow', body: '{}' });
  await assert.rejects(transport.request('https://other.invalid/api/chat/file-operations', { method: 'POST' }), /invalid_media/); assert.equal(calls, 1);
});

test('a failed file reservation is not replayed, and late sticker pages are discarded', async () => {
  const { controller, media } = createFixture(); await controller.start();
  let attempts = 0;
  const port = { ...media, async request() { attempts++; throw Error('synthetic lost reply'); } };
  const d = draft('file', new Blob(['x']), 'a', 'a.txt');
  const limits = controller.snapshot().view!.capabilities.files; assert.ok(limits);
  await assert.rejects(uploadFiles(port, 'fixture-session', '00000000-0000-4000-8000-000000000001', [d], limits, () => true), /lost reply/); assert.equal(attempts, 1);
  let finish!: (response: Response) => void; let active = true;
  const delayed = { ...media, async request() { return new Promise<Response>(resolve => { finish = resolve; }); } };
  const client = new StickerClient(delayed, 'fixture-session', () => active);
  const page = client.page('favorites'); active = false; finish(Response.json({ stickers: [], nextCursor: null })); await assert.rejects(page, /session_changed/);
  controller.stop();
});

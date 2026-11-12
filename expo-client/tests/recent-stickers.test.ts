import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ChatController, type ChatPort } from '../src/cfl/chat';
import { recentStickers, recentStickerIdentity, resolveRecentSticker } from '../src/cfl/recent-stickers';
import { StickerClient } from '../src/cfl/stickers';
import { createFixture } from './fixtures/fixture';
import type { ApiTransport } from '../src/cfl/transport';
import type { ChatMessage, ChatView } from '../vendor/contracts/src/index';

const version = (c: string) => c.repeat(64);
const message = (id: string, role: 'agent' | 'user', stickerId: string, v: string, createdAt: number): ChatMessage => ({
  id, role, text: '', createdAt, operationId: null, turnId: null,
  images: [{ attachmentId: `image-${id}`, name: 'sticker.png', mediaType: 'image/png', availability: 'available', sticker: { id: stickerId, version: version(v) } }],
});
async function setup(messages: ChatMessage[], older: ChatMessage[] = []) {
  const fixture = createFixture(); let changed = (_: ChatView) => {};
  const initial = { ...fixture.read(), messages, before: older.length ? 'older' : null };
  const port: ChatPort = { ...fixture.port, async history() { return { messages: older, before: null }; } };
  const controller = new ChatController('fixture://local', async () => ({ close() {} }) as WebSocket, { async load() { return []; }, async save() {} }, () => '00000000-0000-4000-8000-000000000001', async (_, update) => { changed = update; update(initial); return port; });
  await controller.start();
  return { controller, initial, change: (v: ChatView) => changed(v) };
}

test('recent user and agent stickers use loaded history, most recent version and bounded deterministic ordering', async () => {
  const older = [message('older', 'user', 'duplicate', 'a', 1), message('old-agent', 'agent', 'older', 'a', 2)];
  const messages = [message('newer', 'agent', 'duplicate', 'b', 100), ...Array.from({ length: 35 }, (_, i) => message(`m${i}`, i % 2 ? 'agent' : 'user', `sticker${i}`, 'c', 10 + i))];
  const { controller } = await setup(messages, older);
  try {
    assert.equal(recentStickers(controller)?.items.length, 30);
    await controller.loadOlder();
    const recent = recentStickers(controller)!;
    assert.equal(recent.items.length, 30); assert.equal(recent.items[0].id, 'duplicate'); assert.equal(recent.items[0].version, version('b')); assert.equal(recent.items[0].role, 'agent');
    assert.ok(recent.items.some(item => item.role === 'user')); assert.ok(recent.items.some(item => item.role === 'agent'));
    assert.equal(recent.items.filter(item => item.id === 'duplicate').length, 1);
    assert.deepEqual(recentStickerIdentity(controller, recent, recent.items[0]), { id: 'duplicate', version: version('b') });
    assert.equal(resolveRecentSticker(recent, recent.items[0], []).state, 'unresolved');
    const catalog = [{ id: 'duplicate', version: version('b'), name: 'Test', tags: [], mediaType: 'image/png' as const, available: false }];
    assert.equal(resolveRecentSticker(recent, recent.items[0], catalog).state, 'unavailable');
    assert.deepEqual(recentStickerIdentity(controller, recent, recent.items[0]), { id: 'duplicate', version: version('b') });
  } finally { controller.stop(); }
});

test('identity belongs to observed snapshot and the original controller epoch', async () => {
  const a = await setup([message('m', 'user', 'a', 'a', 1)]), b = await setup([message('m', 'user', 'a', 'a', 1)]);
  try {
    const recent = recentStickers(a.controller)!, item = recent.items[0];
    assert.equal(recentStickerIdentity(b.controller, recent, item), null);
    assert.equal(recentStickerIdentity(a.controller, recent, { ...item, id: 'forged' }), null);
    a.change({ ...a.initial, sessionId: 'B' }); a.change(a.initial);
    assert.equal(recent.current(), false); assert.equal(recentStickerIdentity(a.controller, recent, item), null);
    const again = recentStickers(a.controller)!; a.controller.stop(); await a.controller.start();
    assert.equal(recentStickerIdentity(a.controller, again, again.items[0]), null);
  } finally { a.controller.stop(); b.controller.stop(); }
});

test('unresolved observed identity is staged on explicit send; stale version fails before dispatch', async () => {
  const { controller } = await setup([message('m', 'agent', 'a', 'a', 1)]);
  let stageRequests = 0, dispatches = 0, stale = false;
  const transport: ApiTransport = { origin: 'fixture://local', async read() { throw Error('unused'); }, async request(path, init) {
    assert.equal(path, '/api/stickers/stage'); stageRequests++;
    const input = JSON.parse(String(init?.body)); assert.equal(input.sessionId, 'fixture-session'); assert.deepEqual(input.sticker, { id: 'a', version: version('a') });
    if (stale) return new Response(null, { status: 404 });
    return Response.json({ sessionId: input.sessionId, operationId: input.operationId, image: { attachmentId: 'staged', name: 'test.png', mediaType: 'image/png', availability: 'available', sticker: input.sticker } });
  } };
  try {
    const recent = recentStickers(controller)!, identity = recentStickerIdentity(controller, recent, recent.items[0])!;
    assert.equal(resolveRecentSticker(recent, recent.items[0], []).state, 'unresolved');
    const image = await new StickerClient(transport, recent.sessionId, recent.current).stage('00000000-0000-4000-8000-000000000001', identity);
    assert.equal(image.sticker?.id, 'a'); assert.equal(stageRequests, 1);
    stale = true;
    await assert.rejects(controller.sendPrepared('', async ({ operationId, sessionId, isCurrent, signal }) => ({ images: [await new StickerClient(transport, sessionId, isCurrent, signal).stage(operationId, identity)] })).then(() => { dispatches++; }), /sticker_unavailable/);
    assert.equal(stageRequests, 2); assert.equal(dispatches, 0); assert.equal(controller.snapshot().pending.length, 0);
  } finally { controller.stop(); }
});

test('loading older history adds both sides without duplicating an overlapping message', async () => {
  const newer = message('newer', 'agent', 'b', 'b', 4), older = message('older', 'user', 'a', 'a', 1);
  const { controller } = await setup([newer], [older, newer]);
  try {
    assert.deepEqual(recentStickers(controller)!.items.map(i => i.id), ['b']);
    await controller.loadOlder();
    assert.deepEqual(recentStickers(controller)!.items.map(i => i.id), ['b', 'a']);
    assert.equal(recentStickers(controller)!.items[1].image.attachmentId, 'image-older');
  } finally { controller.stop(); }
});

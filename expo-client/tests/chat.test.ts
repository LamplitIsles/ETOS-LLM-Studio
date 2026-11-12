import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createFixture } from './fixtures/fixture';
import { loadImage, webTransport } from '../src/cfl/transport';
import { ChatController, type ChatPort, type Pending, type PendingStore } from '../src/cfl/chat';
import type { ChatView } from '../vendor/contracts/src/index';

const view = (sessionId = 's'): ChatView => ({ version: 2, sessionId, name: 'test', activeTurnId: null, contextUsage: { tokens: null, capacity: null }, compaction: null, messages: [], before: null, capabilities: { text: true, steer: true, stop: true, images: false } });
test('fixture provides ordered history, synthetic send and authorized image', async () => {
  const { controller, media } = createFixture(); await controller.start(); await controller.loadOlder();
  assert.equal(controller.snapshot().history[0]?.id, 'fixture-older'); assert.equal(controller.snapshot().view?.messages[3]?.files?.[0]?.name, 'sample.txt'); assert.ok(controller.snapshot().view?.messages[4]?.images?.[0]?.sticker); assert.ok(controller.snapshot().view?.messages[5]?.ui); await controller.send('synthetic');
  assert.ok(controller.snapshot().view?.messages.some(message => message.role === 'user' && message.text === 'synthetic'));
  assert.equal(controller.snapshot().view?.messages.at(-1)?.role, 'agent');
  const image = await loadImage(media, 'fixture-image', controller.scope()); assert.equal(image.contentType, 'image/png');
  controller.stop(); await assert.rejects(loadImage(media, 'fixture-image', controller.scope()), /invalid_media/);
});
test('lost admission is persisted and reconciled by lookup, never resubmitted', async () => {
  let entries: Pending[] = [], sends = 0, lookups = 0, update = (_: ChatView) => {};
  const store: PendingStore = { async load() { return entries; }, async save(_, next) { entries = next; } };
  const port: ChatPort = { async history() { return { messages: [], before: null }; }, async submit() { sends++; throw Error('lost'); }, async lookup(id) { lookups++; return { operationId: id, attempt: 1, state: 'submitted', messageId: 'm', turnId: null, error: null }; }, close() {} };
  const c = new ChatController('test', async () => ({ close() {} }) as WebSocket, store, () => '00000000-0000-4000-8000-000000000001', async (_, changed) => { update = changed; changed(view()); return port; });
  await c.start(); await c.send('hello'); assert.equal(entries.length, 1); await c.reconcile(); assert.equal(entries[0]?.state, 'submitted'); assert.equal(sends, 1); assert.ok(lookups >= 1);
  const scope = c.scope(); update(view('other'));  assert.equal(scope(), false); assert.equal(c.snapshot().pending.length, 0); c.stop();
});
test('media fallback rejects missing and stale session responses', async () => {
  let active = true, calls = 0;
  const media = { origin: 'test', async read() { calls++; return new Response(null, { status: 404 }); } };
  await assert.rejects(loadImage(media, 'image', () => active), /missing/); assert.equal(calls, 2);
  const stale = { origin: 'test', async read() { active = false; return new Response(null, { status: 404 }); } };
  await assert.rejects(loadImage(stale, 'image', () => active), /session_changed/);
});
test('web image preview and original use browser cache policy and same-origin authentication', async t => {
  const previous = Object.getOwnPropertyDescriptor(globalThis, 'window');
  t.after(() => { if (previous) Object.defineProperty(globalThis, 'window', previous); else Reflect.deleteProperty(globalThis, 'window'); });
  Object.defineProperty(globalThis, 'window', { configurable: true, value: { location: { origin: 'https://fixture.invalid' } } });
  const requests: { url: string; init?: RequestInit }[] = [];
  t.mock.method(globalThis, 'fetch', async (url: string | URL | Request, init?: RequestInit) => {
    requests.push({ url: String(url), init });
    return requests.length === 1 ? new Response(null, { status: 404 }) : new Response(new Uint8Array([1]), { headers: { 'content-type': 'image/png' } });
  });
  assert.equal((await loadImage(webTransport('https://fixture.invalid'), 'image', () => true)).contentType, 'image/png');
  assert.deepEqual(requests.map(request => request.url), ['https://fixture.invalid/api/chat/media/image/preview', 'https://fixture.invalid/api/chat/media/image/original']);
  for (const request of requests) {
    assert.equal(request.init?.cache, undefined); assert.equal(request.init?.credentials, 'same-origin'); assert.equal(request.init?.redirect, 'error');
  }
});
test('a delayed history page cannot enter a different session', async () => {
  let changed = (_: ChatView) => {}; let resolve!: (value: { messages: []; before: null }) => void;
  const port: ChatPort = { history: async () => new Promise(r => { resolve = r; }), async submit() { throw Error('unused'); }, async lookup() { return null; }, close() {} };
  const store: PendingStore = { async load() { return []; }, async save() {} };
  const c = new ChatController('test', async () => ({ close() {} }) as WebSocket, store, () => 'unused', async (_, fn) => { changed = fn; fn({ ...view(), before: 'cursor' }); return port; });
  await c.start(); const old = c.loadOlder(); changed(view('other')); resolve({ messages: [], before: null }); await assert.rejects(old, /session_changed/); assert.equal(c.snapshot().view?.sessionId, 'other'); c.stop();
});
test('connection loss reconnects and checks unknown operation without replay', async () => {
  let entries: Pending[] = [], connects = 0, sends = 0, lookups = 0, offline = (_: Error) => {};
  const store: PendingStore = { async load() { return entries; }, async save(_, next) { entries = next; } };
  const port: ChatPort = { async history() { return { messages: [], before: null }; }, async submit() { sends++; throw Error('lost'); }, async lookup() { lookups++; return null; }, close() {} };
  const c = new ChatController('test', async () => ({ close() {} }) as WebSocket, store, () => '00000000-0000-4000-8000-000000000002', async (_, fn, fail) => { connects++; offline = fail; fn(view()); return port; });
  await c.start(); await c.send('hello'); offline(Error('disconnected'));
  await new Promise(resolve => setTimeout(resolve, 2150)); assert.equal(connects, 2); assert.equal(sends, 1); assert.ok(lookups >= 1); assert.equal(entries[0]?.state, 'unknown'); c.stop();
});
test('media refuses unauthorised reads and malformed identifiers', async () => {
  let calls = 0; const transport = { origin: 'test', async read() { calls++; return new Response(null, { status: 403 }); } };
  await assert.rejects(loadImage(transport, 'ok', () => true), /access_denied/);
  await assert.rejects(loadImage(transport, '../bad', () => true), /invalid_media/); assert.equal(calls, 1);
});
test('expired absent admission stays unknown without submitting again', async () => {
  let entries: Pending[] = [{ origin: 'test', sessionId: 's', operationId: '00000000-0000-4000-8000-000000000003', text: 'older', createdAt: 0, state: 'unknown' }]; let sends = 0;
  const store: PendingStore = { async load() { return entries; }, async save(_, next) { entries = next; } };
  const port: ChatPort = { async history() { return { messages: [], before: null }; }, async submit() { sends++; throw Error('unexpected'); }, async lookup() { return null; }, close() {} };
  const c = new ChatController('test', async () => ({ close() {} }) as WebSocket, store, () => 'unused', async (_, fn) => { fn(view()); return port; });
  await c.start(); await c.reconcile(); assert.equal(sends, 0); assert.equal(c.snapshot().pending[0]?.state, 'unknown'); c.stop();
});
test('authorization failure is surfaced without reconnecting indefinitely', async () => {
  let connects = 0;
  const store: PendingStore = { async load() { return []; }, async save() {} };
  const c = new ChatController('test', async () => { connects++; throw Object.assign(new Error('expired'), { code: 'authorization_required' }); }, store, () => 'unused');
  await c.start(); assert.equal(c.snapshot().failure, 'access_denied'); assert.equal(c.snapshot().connection, 'offline'); assert.equal(connects, 1); c.stop();
});
test('disconnected socket probes authorization without treating a network outage as logout', async () => {
  const store: PendingStore = { async load() { return []; }, async save() {} };
  let probeDone!: () => void; const probed = new Promise<void>(r => { probeDone = r; });
  const c = new ChatController('test', async () => { throw Error('connection'); }, store, () => 'unused', undefined, async () => { probeDone(); return false; });
  await c.start(); await probed; await Promise.resolve(); assert.equal(c.snapshot().failure, 'access_denied'); c.stop();
});

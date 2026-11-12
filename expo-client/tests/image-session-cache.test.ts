import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createFixture } from './fixtures/fixture';
import type { MediaTransport } from '../src/cfl/transport';

test('one unchanged image mount performs one application read', async () => {
  const { controller } = createFixture(); await controller.start(); let reads = 0;
  const media: MediaTransport = { origin: 'fixture://local', async read() { reads++; return new Response(new Uint8Array([1]), { headers: { 'content-type': 'image/png' } }); } };
  try { await controller.readImage(media, 'photo', () => true, 'original'); assert.equal(reads, 1); }
  finally { controller.stop(); }
});

test('same session image remount does not reread the same variant', async () => {
  const { controller } = createFixture(); await controller.start();
  let reads = 0;
  const media: MediaTransport = { origin: 'fixture://local', async read() { reads++; return new Response(new Uint8Array([1, 2, 3]), { headers: { 'content-type': 'image/png' } }); } };
  // Same lifetime pattern as AuthImage: one effect per mount, each with its own active flag.
  const mount = () => { let active = true; const promise = controller.readImage(media, 'photo', () => active, 'original'); return { promise, unmount() { active = false; } }; };
  try {
    const first = mount(); await first.promise; first.unmount();
    const second = mount(); await second.promise; second.unmount();
    assert.equal(reads, 1, 're-entering the viewport reread the same session image');
  } finally { controller.stop(); }
});

import { createServer } from 'node:http';
import { ChatController, type ChatPort } from '../src/cfl/chat';
import type { ChatView } from '../vendor/contracts/src/index';

async function controllable() {
  const fixture = createFixture();
  const initial = fixture.read();
  let update = (_: ChatView) => {};
  let disconnect = (_: Error) => {};
  const controller = new ChatController('fixture://local', async () => ({ close() {} }) as WebSocket,
    { async load() { return []; }, async save() {} }, () => 'unused',
    async (_, changed, offline) => { update = changed; disconnect = offline; changed(initial); return fixture.port as ChatPort; });
  await controller.start();
  return { controller, initial, update: (v: ChatView) => update(v), disconnect: (e: Error) => disconnect(e) };
}
const png = (bytes: Uint8Array = new Uint8Array([1])) => new Response(new Uint8Array(bytes).buffer, { headers: { 'content-type': 'image/png' } });

test('test-owned HTTP host sees one GET after remount; variants remain distinct', async () => {
  let requests = 0;
  const server = createServer((_req, res) => { requests++; res.writeHead(200, { 'content-type': 'image/png', 'cache-control': 'no-store' }); res.end(Buffer.from([1, 2])); });
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve));
  const address = server.address(); if (!address || typeof address === 'string') throw Error('invalid test host');
  const origin = `http://127.0.0.1:${address.port}`;
  const media: MediaTransport = { origin, read(path, init) { return fetch(origin + path, init); } };
  const { controller } = await controllable();
  try {
    await controller.readImage(media, 'id', () => true, 'original');
    await controller.readImage(media, 'id', () => true, 'original');
    assert.equal(requests, 1);
    await controller.readImage(media, 'id', () => true, 'preview'); assert.equal(requests, 2);
  } finally { controller.stop(); await new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve())); }
});

test('session A→B→A, stop and different transport never reuse bytes', async () => {
  const { controller, initial, update } = await controllable(); let reads = 0;
  const make = (origin: string): MediaTransport => ({ origin, async read() { reads++; return png(new Uint8Array([reads])); } });
  const first = make('fixture://one'), second = make('fixture://two');
  try {
    const firstBytes = await controller.readImage(first, 'id', () => true); firstBytes.bytes[0] = 99;
    assert.equal((await controller.readImage(first, 'id', () => true)).bytes[0], 1);
    await controller.readImage(second, 'id', () => true); assert.equal(reads, 2);
    update({ ...initial, sessionId: 'B' }); await controller.readImage(first, 'id', () => true);
    update(initial); await controller.readImage(first, 'id', () => true); assert.equal(reads, 4);
    controller.stop(); await assert.rejects(controller.readImage(first, 'id', () => true), /session_changed/);
    await controller.start(); await controller.readImage(first, 'id', () => true); assert.equal(reads, 5);
  } finally { controller.stop(); }
});

test('concurrent consumers coalesce; last abort cancels underlying request and discards late response', async () => {
  const { controller } = await controllable(); let reads = 0; const requests: { resolve(value: Response): void; signal?: AbortSignal | null }[] = [];
  const media: MediaTransport = { origin: 'fixture://local', read(_path, init) { reads++; return new Promise(resolve => requests.push({ resolve, signal: init?.signal })); } };
  try {
    const a = new AbortController(), b = new AbortController();
    const p = controller.readImage(media, 'id', () => true, 'original', a.signal), q = controller.readImage(media, 'id', () => true, 'original', b.signal);
    a.abort(); await assert.rejects(p, /aborted/); assert.equal(requests[0].signal?.aborted, false);
    requests[0].resolve(png(new Uint8Array([2]))); assert.equal((await q).bytes[0], 2); assert.equal(reads, 1);
    const c = new AbortController(); const stale = controller.readImage(media, 'other', () => true, 'original', c.signal); c.abort(); await assert.rejects(stale, /aborted/); assert.equal(requests[1].signal?.aborted, true);
    const fresh = controller.readImage(media, 'other', () => true, 'original'); requests[1].resolve(png(new Uint8Array([3]))); requests[2].resolve(png(new Uint8Array([4])));
    assert.equal((await fresh).bytes[0], 4); assert.equal((await controller.readImage(media, 'other', () => true, 'original')).bytes[0], 4);
  } finally { controller.stop(); }
});

test('switch and authorization denial clear and reject outstanding reads', async () => {
  const { controller, initial, update, disconnect } = await controllable(); let resolve!: (v: Response) => void; let reads = 0;
  const media: MediaTransport = { origin: 'fixture://local', read(path) { reads++; return path.includes('slow') ? new Promise(r => { resolve = r; }) : Promise.resolve(png()); } };
  try {
    await controller.readImage(media, 'cached', () => true);
    const delayed = controller.readImage(media, 'slow', () => true); update({ ...initial, sessionId: 'B' }); await assert.rejects(delayed, /session_changed/); resolve(png());
    await controller.readImage(media, 'cached', () => true); assert.equal(reads, 3);
    disconnect(Object.assign(new Error('unauthorized'), { code: 'authorization_required' }));
    await assert.rejects(controller.readImage(media, 'cached', () => true), /access_denied/); assert.equal(reads, 3);
  } finally { controller.stop(); }
});

test('401/403 do not fall back to any cached image; count, bytes and freshness are bounded', async t => {
  const { controller } = await controllable(); let reads = 0, denied = false;
  const clock = t.mock.method(Date, 'now', () => 1000);
  const media: MediaTransport = { origin: 'fixture://local', async read(path) { reads++; return denied && path.includes('denied') ? new Response(null, { status: 403 }) : png(new Uint8Array(1)); } };
  try {
    await controller.readImage(media, 'first', () => true);
    denied = true; await assert.rejects(controller.readImage(media, 'denied', () => true), /access_denied/);
    await controller.readImage(media, 'first', () => true); assert.equal(reads, 3);
    for (let i = 0; i < 49; i++) await controller.readImage(media, `id${i}`, () => true);
    const before = reads; await controller.readImage(media, 'first', () => true); assert.equal(reads, before + 1);
    clock.mock.mockImplementation(() => 1000 + 30 * 24 * 60 * 60 * 1000);
    await controller.readImage(media, 'first', () => true); assert.equal(reads, before + 2);
    let bigReads = 0; const big: MediaTransport = { origin: 'fixture://big', async read() { bigReads++; return png(new Uint8Array(6_000_000)); } };
    await controller.readImage(big, 'a', () => true); await controller.readImage(big, 'b', () => true); await controller.readImage(big, 'c', () => true); await controller.readImage(big, 'a', () => true); assert.equal(bigReads, 4);
  } finally { controller.stop(); }
});

test('in-flight concurrency is bounded and stop aborts all waiters', async () => {
  const { controller } = await controllable(); let reads = 0; const signals: AbortSignal[] = [];
  const media: MediaTransport = { origin: 'fixture://local', read(_path, init) { reads++; signals.push(init!.signal as AbortSignal); return new Promise(() => {}); } };
  try {
    const pending = Array.from({ length: 16 }, (_, i) => controller.readImage(media, `id${i}`, () => true));
    const settlements = Promise.all(pending.map(p => assert.rejects(p, /session_changed/)));
    const overflow = controller.readImage(media, 'overflow', () => true); const overflowSettlement = assert.rejects(overflow, /session_changed/); assert.equal(reads, 16);
    controller.stop(); await settlements; await overflowSettlement; assert.ok(signals.every(signal => signal.aborted));
  } finally { controller.stop(); }
});

test('a network error and inactive mount are never cached', async () => {
  const { controller } = await controllable(); let calls = 0, active = true; let resolve!: (value: Response) => void;
  const media: MediaTransport = { origin: 'fixture://local', read() { calls++; if (calls === 1) return Promise.reject(Error('network')); if (calls === 2) return new Promise(r => { resolve = r; }); return Promise.resolve(png()); } };
  try {
    await assert.rejects(controller.readImage(media, 'id', () => true), /network/);
    const delayed = controller.readImage(media, 'id', () => active); active = false; resolve(png()); await assert.rejects(delayed, /session_changed/);
    await controller.readImage(media, 'id', () => true); assert.equal(calls, 3);
  } finally { controller.stop(); }
});

test('a queued cache hit cannot escape a synchronous stop', async () => {
  const { controller } = await controllable();
  const media: MediaTransport = { origin: 'fixture://local', async read() { return png(); } };
  await controller.readImage(media, 'id', () => true);
  const hit = controller.readImage(media, 'id', () => true);
  controller.stop(); await assert.rejects(hit, /session_changed/);
});

test('session change rejects both queued and running reads and never starts old queued work', async () => {
  const { controller, initial, update } = await controllable(); let calls = 0;
  const media: MediaTransport = { origin: 'fixture://local', read(_path, init) { calls++; return new Promise((_resolve, reject) => init?.signal?.addEventListener('abort', () => reject(Error('aborted')), { once: true })); } };
  try {
    const all = Array.from({ length: 20 }, (_, i) => controller.readImage(media, `queued${i}`, () => true).then(() => 'ready', error => error.message));
    assert.equal(calls, 16); update({ ...initial, sessionId: 'B' }); assert.ok((await Promise.all(all)).every(value => value === 'session_changed'));
    await new Promise(resolve => setImmediate(resolve)); assert.equal(calls, 16);
  } finally { controller.stop(); }
});

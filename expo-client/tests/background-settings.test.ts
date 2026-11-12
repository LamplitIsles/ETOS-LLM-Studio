import { test } from 'node:test';
import assert from 'node:assert/strict';
import { BackgroundSettingsClient, MAX_BACKGROUND_BYTES, type BackgroundAsset } from '../src/cfl/background-settings';
import { loadAppearance, loadAppearanceImage } from '../src/cfl/appearance';
import { ChatController, type ChatPort } from '../src/cfl/chat';
import { nativeTransport, webTransport, type ApiTransport } from '../src/cfl/transport';
import { createFixture } from './fixtures/fixture';
import { fixtureImageBase64 } from './fixtures/fixture-art';
import type { ChatView } from '../vendor/contracts/src/index';

const sample = () => new Blob([Buffer.from(fixtureImageBase64, 'base64')], { type: 'image/png' });
const asset = (body = sample()): BackgroundAsset => ({ body, mediaType: 'image/png', size: body.size });
const fake = (fn: ApiTransport['request']): ApiTransport => ({ origin: 'fixture://local', async read() { throw Error('unused'); }, request: fn });
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(r => { resolve = r; }); return { promise, resolve }; }
async function setup(origin = 'fixture://local') {
  const fixture = createFixture(), initial = fixture.read(); let update = (_: ChatView) => {}; let offline = (_: Error) => {};
  const controller = new ChatController(origin, async () => ({ close() {} }) as WebSocket, { async load() { return []; }, async save() {} }, () => 'unused', async (_, changed, disconnected) => { update = changed; offline = disconnected; changed(initial); return fixture.port as ChatPort; });
  await controller.start(); return { controller, initial, media: fixture.media, change: (v: ChatView) => update(v), disconnect: (e: Error) => offline(e) };
}

test('synthetic upload sets each background and existing appearance reads it with opposite-slot fallback', async () => {
  const { controller, media } = await setup(); const client = new BackgroundSettingsClient(controller, media); const body = sample(); let releases = 0;
  const draft = { ...asset(body), release() { releases++; } };
  try {
    assert.deepEqual(await client.load(), { landscape: false, portrait: false });
    const result = await client.save('landscape', draft); assert.deepEqual(result, { state: 'saved', snapshot: { landscape: true, portrait: false } });
    assert.equal(releases, 0); assert.deepEqual(await client.load(), { landscape: true, portrait: false });
    assert.equal((await loadAppearance(media, client.current))?.backgrounds, true);
    const portrait = await loadAppearanceImage(media, 'portrait', client.current); assert.deepEqual(portrait?.bytes, new Uint8Array(await body.arrayBuffer()));
    assert.equal((await client.save('portrait', draft)).state, 'saved'); assert.deepEqual(await client.load(), { landscape: true, portrait: true });
  } finally { draft.release(); controller.stop(); }
  assert.equal(releases, 1);
});

test('preflight rejects unsupported type, zero/oversize, size mismatch and invalid signatures without dispatch', async () => {
  const { controller } = await setup(); let calls = 0;
  const client = new BackgroundSettingsClient(controller, fake(async () => { calls++; return Response.json({ landscape: true, portrait: false }); }));
  try {
    await assert.rejects(client.save('landscape', { ...asset(), mediaType: 'image/heic' }), /invalid_background_type/);
    const zero = new Blob([]); await assert.rejects(client.save('landscape', asset(zero)), /invalid_background/);
    const large = new Blob([new Uint8Array(MAX_BACKGROUND_BYTES + 1)]); await assert.rejects(client.save('landscape', asset(large)), /background_too_large/);
    const value = asset(); await assert.rejects(client.save('landscape', { ...value, size: value.size + 1 }), /invalid_background/);
    await assert.rejects(client.save('landscape', asset(new Blob(['not png']))), /invalid_background/);
    await assert.rejects(client.save('landscape', { ...value, mediaType: 'image/jpeg' }), /invalid_background/);
    await assert.rejects(client.save('wrong' as never, value), /invalid_background_kind/); assert.equal(calls, 0);
  } finally { controller.stop(); }
});

test('all allowed media signatures are sent as exact raw bytes and matching MIME', async () => {
  const { controller } = await setup(); const sent: { type: string | null; bytes: Uint8Array }[] = [];
  const client = new BackgroundSettingsClient(controller, fake(async (_, init) => { sent.push({ type: new Headers(init?.headers).get('content-type'), bytes: new Uint8Array(init!.body as ArrayBuffer) }); return Response.json({ landscape: true, portrait: false }); }));
  const inputs = [ ['image/png', [137,80,78,71,13,10,26,10]], ['image/jpeg', [255,216,255]], ['image/gif', [71,73,70,56,57,97]], ['image/webp', [82,73,70,70,0,0,0,0,87,69,66,80]] ] as const;
  try { for (const [type, bytes] of inputs) { const body = new Blob([new Uint8Array(bytes)], { type }); assert.equal((await client.save('landscape', { body, mediaType: type, size: body.size })).state, 'saved'); assert.equal(sent.at(-1)?.type, type); assert.deepEqual([...sent.at(-1)!.bytes], [...bytes]); } }
  finally { controller.stop(); }
});

test('uncertain, malformed, unauthorized-after-commit and 5xx are unknown and never retried', async () => {
  const { controller } = await setup(); let writes = 0, mode = 0;
  const client = new BackgroundSettingsClient(controller, fake(async () => { writes++; if (mode === 0) throw Error('network after dispatch'); if (mode === 1) return new Response(null, { status: 401 }); if (mode === 2) return new Response(null, { status: 403 }); if (mode === 3) return Response.json({ landscape: true, portrait: false, extra: true }); return Response.json({ error: { code: 'background_settings_unavailable' } }, { status: 503 }); }));
  try { for (mode = 0; mode < 5; mode++) assert.equal((await client.save('landscape', asset())).state, 'unknown'); assert.equal(writes, 5); }
  finally { controller.stop(); }
});

test('explicit known server errors remain distinct; no automatic retry or refresh', async () => {
  const { controller } = await setup(); let calls = 0, status = 409, code = 'background_settings_busy';
  const client = new BackgroundSettingsClient(controller, fake(async () => { calls++; return Response.json({ error: { code } }, { status }); }));
  try { for (const [s, c] of [[409, 'background_settings_busy'], [400, 'invalid_background'], [413, 'background_too_large'], [415, 'invalid_background_type']] as const) { status = s; code = c; assert.equal((await client.save('portrait', asset())).state, c); } assert.equal(calls, 4); }
  finally { controller.stop(); }
});

test('scope and component disposal reject before dispatch; after dispatch return unknown', async () => {
  const { controller, initial, change } = await setup(); const fileRead = deferred<ArrayBuffer>(), post = deferred<Response>(); let writes = 0, alive = true;
  const transport = fake(async () => { writes++; return post.promise; });
  let client = new BackgroundSettingsClient(controller, transport, () => alive);
  const input = asset(); const lateFile = { ...input, body: { ...input.body, size: input.size, arrayBuffer: () => fileRead.promise } as Blob };
  try {
    const preparing = client.save('landscape', lateFile); alive = false; fileRead.resolve(await input.body.arrayBuffer()); await assert.rejects(preparing, /session_changed/); assert.equal(writes, 0);
    alive = true; assert.equal(client.current(), false); client = new BackgroundSettingsClient(controller, transport, () => alive); const pending = client.save('landscape', input); await new Promise(resolve => setImmediate(resolve)); assert.equal(writes, 1);
    change({ ...initial, sessionId: 'B' }); change(initial); post.resolve(Response.json({ landscape: true, portrait: false })); assert.equal((await pending).state, 'unknown');
    await assert.rejects(client.load(), /session_changed/); assert.equal(writes, 1);
  } finally { controller.stop(); }
});

test('concurrent writes are locked across instances; stale reads cannot overwrite newer results', async () => {
  const { controller } = await setup(); const first = deferred<Response>(), second = deferred<Response>(), posting = deferred<Response>(); let gets = 0, posts = 0;
  const transport = fake(async (_, init) => { if (init?.method === 'POST') { posts++; return posting.promise; } return [first, second][gets++].promise; });
  const a = new BackgroundSettingsClient(controller, transport), b = new BackgroundSettingsClient(controller, transport);
  try {
    const old = a.load(), fresh = b.load(); second.resolve(Response.json({ landscape: true, portrait: false })); assert.equal((await fresh).landscape, true); first.resolve(Response.json({ landscape: false, portrait: false })); await assert.rejects(old, /background_superseded/);
    const save = a.save('portrait', asset()); await new Promise(resolve => setImmediate(resolve)); await assert.rejects(b.save('landscape', asset()), /background_write_pending/); await assert.rejects(b.load(), /background_write_pending/);
    posting.resolve(Response.json({ landscape: true, portrait: true })); assert.equal((await save).state, 'saved'); assert.equal(posts, 1);
  } finally { controller.stop(); }
});

test('read rejects unsupported/auth/invalid output and cannot bind a different origin', async () => {
  const { controller } = await setup(); let response = Response.json({ landscape: false, portrait: false });
  const client = new BackgroundSettingsClient(controller, fake(async () => response));
  try {
    response = Response.json({}, { status: 401 }); await assert.rejects(client.load(), /access_denied/);
    response = Response.json({}, { status: 404 }); await assert.rejects(client.load(), /unsupported/);
    response = Response.json({ landscape: true, portrait: false, extra: true }); await assert.rejects(client.load(), /invalid_background_settings/);
    assert.throws(() => new BackgroundSettingsClient(controller, { ...fake(async () => response), origin: 'fixture://other' }), /origin_mismatch/);
  } finally { controller.stop(); }
});

test('native bearer and web cookie requests preserve origin and redirect protection for GET and POST', async t => {
  const native = await setup('https://fixture.invalid'); const calls: { url: string; init?: RequestInit }[] = [];
  const fetcher: typeof fetch = async (url, init) => { calls.push({ url: String(url), init }); return Response.json(init?.method === 'POST' ? { landscape: true, portrait: false } : { landscape: false, portrait: false }); };
  const media = nativeTransport('https://fixture.invalid', { async tokenFor() { return 'synthetic-token'; } } as never, fetcher);
  try { const client = new BackgroundSettingsClient(native.controller, media); await client.load(); assert.equal((await client.save('landscape', asset())).state, 'saved'); for (const call of calls) { assert.equal(call.init?.redirect, 'error'); assert.equal(call.init?.credentials, 'omit'); assert.equal(new Headers(call.init?.headers).get('authorization'), 'Bearer synthetic-token'); } }
  finally { native.controller.stop(); }
  const old = Object.getOwnPropertyDescriptor(globalThis, 'window'); t.after(() => { if (old) Object.defineProperty(globalThis, 'window', old); else Reflect.deleteProperty(globalThis, 'window'); });
  Object.defineProperty(globalThis, 'window', { configurable: true, value: { location: { origin: 'https://fixture.invalid' } } }); t.mock.method(globalThis, 'fetch', fetcher);
  const web = await setup('https://fixture.invalid');
  try { const client = new BackgroundSettingsClient(web.controller, webTransport('https://fixture.invalid')); await client.load(); assert.equal((await client.save('landscape', asset())).state, 'saved'); for (const call of calls.slice(2)) { assert.equal(call.init?.redirect, 'error'); assert.equal(call.init?.credentials, 'same-origin'); assert.equal(new Headers(call.init?.headers).get('authorization'), null); } }
  finally { web.controller.stop(); }
});

test('connection loss or stop after dispatch returns unknown; a stale client cannot be revived', async () => {
  const { controller, disconnect } = await setup(); const pending = deferred<Response>(); let writes = 0;
  const client = new BackgroundSettingsClient(controller, fake(async () => { writes++; return pending.promise; }));
  try { const task = client.save('portrait', asset()); await new Promise(resolve => setImmediate(resolve)); disconnect(Error('offline')); pending.resolve(Response.json({ landscape: false, portrait: true })); assert.equal((await task).state, 'unknown'); assert.equal(writes, 1); await assert.rejects(client.load(), /session_changed/); }
  finally { controller.stop(); }
});

test('disposing while file preparation or an HTTP write is outstanding stays invalid after remount', async () => {
  const { controller } = await setup(); let writes = 0; const post = deferred<Response>(); const file = deferred<ArrayBuffer>();
  const transport = fake(async () => { writes++; return post.promise; });
  const first = new BackgroundSettingsClient(controller, transport); const value = asset();
  try {
    const source = { ...value, body: { size: value.size, arrayBuffer: () => file.promise } as Blob };
    const reading = first.save('portrait', source); first.dispose(); file.resolve(await value.body.arrayBuffer()); await assert.rejects(reading, /session_changed/); assert.equal(first.current(), false); assert.equal(writes, 0);
    const second = new BackgroundSettingsClient(controller, transport); const writing = second.save('portrait', value); await new Promise(resolve => setImmediate(resolve)); second.dispose();
    post.resolve(Response.json({ landscape: false, portrait: true })); assert.equal((await writing).state, 'unknown'); assert.equal(second.current(), false); assert.equal(writes, 1);
  } finally { controller.stop(); }
});

test('actual bytes must match declared length and stop rejects queued preparation', async () => {
  const { controller } = await setup(); let calls = 0; const file = deferred<ArrayBuffer>();
  const client = new BackgroundSettingsClient(controller, fake(async () => { calls++; return Response.json({ landscape: true, portrait: false }); }));
  const value = asset();
  try {
    const altered = { ...value, body: { size: value.size, async arrayBuffer() { return new Uint8Array([137,80,78,71,13,10,26,10]).buffer; } } as Blob };
    await assert.rejects(client.save('landscape', altered), /invalid_background/); assert.equal(calls, 0);
    const waiting = client.save('landscape', { ...value, body: { size: value.size, arrayBuffer: () => file.promise } as Blob });
    controller.stop(); file.resolve(await value.body.arrayBuffer()); await assert.rejects(waiting, /session_changed/); assert.equal(calls, 0);
  } finally { controller.stop(); }
});

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ModelSettingsClient } from '../src/cfl/model-settings';
import { ChatController, type ChatPort } from '../src/cfl/chat';
import { nativeTransport, webTransport, type ApiTransport } from '../src/cfl/transport';
import { createFixture } from './fixtures/fixture';
import type { ChatView } from '../vendor/contracts/src/index';

const selection = { model: 'gpt-6.1-terra' as const, fast: false };
const snapshot = (sessionId = 'fixture-session') => ({ sessionId, currentModel: 'gpt-6.1-sol', fast: true, busy: false });
async function setup(origin = 'fixture://local') {
  const fixture = createFixture(), initial = fixture.read(); let change = (_: ChatView) => {}; let disconnected = (_: Error) => {};
  const controller = new ChatController(origin, async () => ({ close() {} }) as WebSocket, { async load() { return []; }, async save() {} }, () => 'unused', async (_, update, offline) => { change = update; disconnected = offline; update(initial); return fixture.port as ChatPort; });
  await controller.start(); return { controller, initial, change: (v: ChatView) => change(v), disconnect: (e: Error) => disconnected(e), media: fixture.media };
}
const fake = (fn: ApiTransport['request']): ApiTransport => ({ origin: 'fixture://local', async read() { throw Error('unused'); }, request: fn });
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(r => { resolve = r; }); return { promise, resolve }; }

test('explicit selection uses exact session and previous values, and consumes snapshots', async () => {
  const { controller, media } = await setup(); const calls: { method?: string; body?: unknown }[] = [];
  const transport: ApiTransport = { ...media, async request(path, init) { calls.push({ method: init?.method, body: init?.body && JSON.parse(String(init.body)) }); return media.request(path, init); } };
  const client = new ModelSettingsClient(controller, transport);
  try {
    const old = await client.load(); assert.equal(old.currentModel, 'gpt-6.1-sol');
    const result = await client.select(old, selection); assert.equal(result.state, 'saved');
    assert.deepEqual(calls[1].body, { sessionId: 'fixture-session', expectedModel: 'gpt-6.1-sol', expectedFast: true, model: 'gpt-6.1-terra', fast: false });
    await assert.rejects(client.select(old, selection), /model_snapshot_stale/); assert.equal(calls.length, 2);
    assert.equal((await client.load()).currentModel, 'gpt-6.1-terra');
  } finally { controller.stop(); }
});

test('stale and busy conflict are distinct, refresh once, and never replay', async () => {
  const { controller } = await setup(); let code = 'stale_model', reads = 0, writes = 0;
  const transport = fake(async (_, init) => { if (init?.method !== 'POST') { reads++; return Response.json(snapshot()); } writes++; return Response.json({ error: { code, message: 'synthetic' } }, { status: 409 }); });
  const client = new ModelSettingsClient(controller, transport);
  try {
    const a = await client.load(); const stale = await client.select(a, selection); assert.equal(stale.state, 'stale_model'); assert.ok('snapshot' in stale && stale.snapshot);
    code = 'model_busy'; const b = await client.load(); const busy = await client.select(b, selection); assert.equal(busy.state, 'model_busy'); assert.ok('snapshot' in busy && busy.snapshot);
    assert.equal(writes, 2); assert.equal(reads, 4);
  } finally { controller.stop(); }
});

test('network loss or invalid post response is unknown, never replayed, old snapshot unusable', async () => {
  const { controller } = await setup(); let writes = 0; let mode = 0;
  const client = new ModelSettingsClient(controller, fake(async (_, init) => { if (init?.method !== 'POST') return Response.json(snapshot()); writes++; if (!mode) throw Error('connection lost after dispatch'); return Response.json({ ...snapshot(), currentModel: selection.model, unexpected: true }); }));
  try {
    const a = await client.load(); assert.equal((await client.select(a, selection)).state, 'unknown');
    await assert.rejects(client.select(a, selection), /model_snapshot_stale/); assert.equal(writes, 1);
    mode++; const b = await client.load(); assert.equal((await client.select(b, selection)).state, 'unknown'); assert.equal(writes, 2);
  } finally { controller.stop(); }
});

test('session A→B→A and disconnect discard delayed reads and return unknown for dispatched writes', async () => {
  const { controller, initial, change, disconnect } = await setup(); const load = deferred<Response>(), post = deferred<Response>(); let phase = 0, writes = 0;
  const client = new ModelSettingsClient(controller, fake(async (_, init) => { if (init?.method === 'POST') { writes++; return post.promise; } return phase++ ? Response.json(snapshot()) : load.promise; }));
  try {
    const oldLoad = client.load(); change({ ...initial, sessionId: 'B' }); change(initial); load.resolve(Response.json(snapshot())); await assert.rejects(oldLoad, /session_changed/);
    const current = await client.load(); const write = client.select(current, selection); disconnect(Error('disconnected'));
    post.resolve(Response.json({ ...snapshot(), currentModel: selection.model, fast: false })); assert.equal((await write).state, 'unknown'); assert.equal(writes, 1);
    await assert.rejects(client.load(), /offline/);
  } finally { controller.stop(); }
});

test('concurrent reads supersede stale results; writes lock all clients for the controller', async () => {
  const { controller } = await setup(); const one = deferred<Response>(), two = deferred<Response>(), post = deferred<Response>(); let n = 0, writes = 0;
  const transport = fake(async (_, init) => { if (init?.method === 'POST') { writes++; return post.promise; } return [one, two][n++].promise; });
  const a = new ModelSettingsClient(controller, transport), b = new ModelSettingsClient(controller, transport);
  try {
    const first = a.load(), second = b.load(); two.resolve(Response.json(snapshot())); const current = await second; one.resolve(Response.json(snapshot())); await assert.rejects(first, /model_superseded/);
    const update = a.select(current, selection); await assert.rejects(b.select(current, selection), /model_write_pending/); await assert.rejects(b.load(), /model_write_pending/);
    post.resolve(Response.json({ ...snapshot(), currentModel: selection.model, fast: false })); assert.equal((await update).state, 'saved'); assert.equal(writes, 1);
  } finally { controller.stop(); }
});

test('invalid inputs, response schema, authentication and error codes are bounded', async () => {
  const { controller } = await setup(); let getStatus = 200, getBody: unknown = snapshot(), postStatus = 400, postBody: unknown = { error: { code: 'invalid_model' } }, writes = 0;
  const client = new ModelSettingsClient(controller, fake(async (_, init) => init?.method === 'POST' ? (writes++, Response.json(postBody, { status: postStatus })) : Response.json(getBody, { status: getStatus })));
  try {
    for (const value of [{ ...snapshot(), sessionId: 'other' }, { ...snapshot(), busy: 1 }, { ...snapshot(), extra: true }, { ...snapshot(), currentModel: 'bad\nname' }]) { getBody = value; await assert.rejects(client.load(), /invalid_model_settings/); }
    getBody = snapshot(); getStatus = 401; await assert.rejects(client.load(), /access_denied/); getStatus = 404; await assert.rejects(client.load(), /unsupported/); getStatus = 200;
    const a = await client.load(); await assert.rejects(client.select(a, { model: 'bad', fast: false } as never), /invalid_model_selection/); assert.equal(writes, 0);
    assert.equal((await client.select(a, selection)).state, 'invalid_model');
    const b = await client.load(); postStatus = 403; assert.equal((await client.select(b, selection)).state, 'access_denied');
    const c = await client.load(); postStatus = 409; postBody = { error: { code: 'other' } }; assert.equal((await client.select(c, selection)).state, 'unknown');
  } finally { controller.stop(); }
});

test('native and web transports keep existing authorization, same-origin and redirect policy', async t => {
  const native = await setup('https://fixture.invalid'); const seen: { url: string; init?: RequestInit }[] = [];
  const fetcher: typeof fetch = async (url, init) => { seen.push({ url: String(url), init }); return Response.json(init?.method === 'POST' ? { ...snapshot(), currentModel: selection.model, fast: selection.fast } : snapshot()); };
  const media = nativeTransport('https://fixture.invalid', { async tokenFor() { return 'fixture-token'; } } as never, fetcher);
  try { const client = new ModelSettingsClient(native.controller, media); assert.equal((await client.select(await client.load(), selection)).state, 'saved'); for (const call of seen) { assert.equal(call.init?.redirect, 'error'); assert.equal(new Headers(call.init?.headers).get('authorization'), 'Bearer fixture-token'); assert.equal(call.init?.credentials, 'omit'); } } finally { native.controller.stop(); }
  const old = Object.getOwnPropertyDescriptor(globalThis, 'window'); t.after(() => { if (old) Object.defineProperty(globalThis, 'window', old); else Reflect.deleteProperty(globalThis, 'window'); });
  Object.defineProperty(globalThis, 'window', { configurable: true, value: { location: { origin: 'https://fixture.invalid' } } });
  t.mock.method(globalThis, 'fetch', fetcher);
  const web = await setup('https://fixture.invalid');
  try { const client = new ModelSettingsClient(web.controller, webTransport('https://fixture.invalid')); assert.equal((await client.select(await client.load(), selection)).state, 'saved'); for (const call of seen.slice(2)) { assert.equal(call.init?.redirect, 'error'); assert.equal(call.init?.credentials, 'same-origin'); assert.equal(new Headers(call.init?.headers).get('authorization'), null); } } finally { web.controller.stop(); }
});

test('write scope A→B→A returns unknown and a failed conflict refresh does not hide conflict', async () => {
  const { controller, initial, change } = await setup(); const post = deferred<Response>(); let getCalls = 0, posts = 0;
  const client = new ModelSettingsClient(controller, fake(async (_, init) => { if (init?.method === 'POST') { posts++; return post.promise; } getCalls++; return Response.json(snapshot()); }));
  try {
    const before = await client.load(); const writing = client.select(before, selection);
    change({ ...initial, sessionId: 'B' }); change(initial);
    post.resolve(Response.json({ ...snapshot(), currentModel: selection.model, fast: selection.fast }));
    assert.equal((await writing).state, 'unknown'); await assert.rejects(client.select(before, selection), /model_snapshot_stale/); assert.equal(posts, 1);
    let reads = 0;
    const other = new ModelSettingsClient(controller, fake(async (_, init) => { if (init?.method === 'POST') return Response.json({ error: { code: 'model_busy' } }, { status: 409 }); if (++reads > 1) throw Error('lost refresh'); return Response.json(snapshot()); }));
    const read = await other.load(); const result = await other.select(read, selection); assert.deepEqual(result, { state: 'model_busy', snapshot: null }); assert.equal(reads, 2);
  } finally { controller.stop(); }
});

test('late invalidated body, oversized data and wrong MIME never yield a saved result', async () => {
  const { controller, initial, change } = await setup(); let postCount = 0, finish!: () => void;
  const client = new ModelSettingsClient(controller, fake(async (_, init) => {
    if (init?.method !== 'POST') return Response.json(snapshot()); postCount++;
    if (postCount === 1) return new Response(new ReadableStream({ start(stream) { finish = () => { stream.enqueue(new TextEncoder().encode(JSON.stringify({ ...snapshot(), currentModel: selection.model, fast: selection.fast }))); stream.close(); }; } }), { headers: { 'content-type': 'application/json' } });
    if (postCount === 2) return new Response('x'.repeat(65537), { headers: { 'content-type': 'application/json' } });
    return new Response('{}', { headers: { 'content-type': 'text/plain' } });
  }));
  try {
    const before = await client.load(); const pending = client.select(before, selection); await new Promise(resolve => setImmediate(resolve)); change({ ...initial, sessionId: 'B' }); change(initial); finish(); assert.equal((await pending).state, 'unknown');
    const next = await client.load(); assert.equal((await client.select(next, selection)).state, 'unknown');
    const last = await client.load(); assert.equal((await client.select(last, selection)).state, 'unknown'); assert.equal(postCount, 3);
  } finally { controller.stop(); }
});

test('stopped write remains unknown and later reads are offline', async () => {
  const { controller } = await setup(); const wait = deferred<Response>(); let writing = false;
  const client = new ModelSettingsClient(controller, fake(async (_, init) => { if (init?.method === 'POST') { writing = true; return wait.promise; } return Response.json(snapshot()); }));
  const value = await client.load(); const result = client.select(value, selection); assert.equal(writing, true); controller.stop();
  wait.resolve(Response.json({ ...snapshot(), currentModel: selection.model, fast: selection.fast })); assert.equal((await result).state, 'unknown');
  await assert.rejects(client.load(), /offline/);
});

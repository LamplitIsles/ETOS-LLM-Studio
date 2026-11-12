import { test } from 'node:test';
import assert from 'node:assert/strict';
import { TtsSettingsClient } from '../src/cfl/tts-settings';
import { ChatController, type ChatPort } from '../src/cfl/chat';
import { nativeTransport, webTransport, type ApiTransport } from '../src/cfl/transport';
import { createFixture } from './fixtures/fixture';
import type { ChatView } from '../vendor/contracts/src/index';

const initial = () => ({ provider: 'minimax', voices: { minimax: 'fixture-voice', alibaba: '', bytedance: '', elevenlabs: '' }, speeds: { minimax: null, bytedance: null }, configured: { alibaba: false, bytedance: false, elevenlabs: false } });
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(r => { resolve = r; }); return { promise, resolve }; }
const fake = (request: ApiTransport['request']): ApiTransport => ({ origin: 'fixture://local', async read() { throw Error('unused'); }, request });
async function setup(origin = 'fixture://local') {
  const fixture = createFixture(), initialView = fixture.read(); let update = (_: ChatView) => {}; let disconnect = (_: Error) => {};
  const controller = new ChatController(origin, async () => ({ close() {} }) as WebSocket, { async load() { return []; }, async save() {} }, () => 'unused', async (_, changed, offline) => { update = changed; disconnect = offline; changed(initialView); return fixture.port as ChatPort; });
  await controller.start(); return { controller, media: fixture.media, initialView, change: (v: ChatView) => update(v), disconnect: (e: Error) => disconnect(e) };
}

test('synthetic settings, all providers, key and explicitly requested paginated voices', async () => {
  const { controller, media } = await setup(); const calls: string[] = [];
  const transport: ApiTransport = { ...media, async request(path, init) { calls.push(`${init?.method ?? 'GET'} ${path}`); return media.request(path, init); } };
  const client = new TtsSettingsClient(controller, transport);
  try {
    assert.equal((await client.load()).provider, 'minimax'); assert.deepEqual(calls, ['GET /api/tts/settings']);
    for (const provider of ['minimax', 'alibaba', 'bytedance', 'elevenlabs'] as const) {
      const result = await client.save({ provider, voice: ' fixture-voice ', speed: provider === 'minimax' || provider === 'bytedance' ? 1.25 : null });
      assert.equal(result.state, 'saved'); if (result.state === 'saved') assert.equal(result.snapshot.voices[provider], 'fixture-voice');
    }
    assert.ok(calls.every(call => !call.includes('/voices')));
    await assert.rejects(client.listElevenLabsVoices(), /tts_key_required/);
    for (const provider of ['alibaba', 'bytedance', 'elevenlabs'] as const) assert.deepEqual(await client.setKey(provider, 'fixture-key'), { state: 'saved' });
    const state = await client.load(); assert.deepEqual(state.configured, { alibaba: true, bytedance: true, elevenlabs: true }); assert.ok(!JSON.stringify(state).includes('fixture-key'));
    const page = await client.listElevenLabsVoices(); assert.equal(page.voices[0].id, 'fixture-voice-1'); assert.equal(page.nextCursor, 'fixture-next');
    const next = await client.listElevenLabsVoices(page.nextCursor!); assert.equal(next.voices[0].id, 'fixture-voice-2'); assert.equal(next.nextCursor, null);
  } finally { client.dispose(); controller.stop(); }
});

test('invalid settings, keys and cursors are rejected before network without exposing values', async () => {
  const { controller } = await setup(); let calls = 0; const client = new TtsSettingsClient(controller, fake(async () => { calls++; return Response.json(initial()); }));
  try {
    for (const input of [{ provider: 'bad', voice: 'v', speed: null }, { provider: 'minimax', voice: ' ', speed: null }, { provider: 'minimax', voice: 'a'.repeat(513), speed: 1 }, { provider: 'bytedance', voice: 'v', speed: 2.1 }, { provider: 'alibaba', voice: 'v', speed: 1 }, { provider: 'elevenlabs', voice: 'v', speed: 1 }, { provider: 'minimax', voice: 'v', speed: null, extra: true }]) await assert.rejects(client.save(input as never), /invalid_tts_settings/);
    for (const key of ['', 'bad key', ' fixture', 'a'.repeat(513)]) { const error = await client.setKey('alibaba', key).catch(e => e); assert.equal(error.message, 'invalid_tts_key'); assert.ok(!JSON.stringify(error).includes(key || 'synthetic-secret')); }
    await assert.rejects(client.setKey('minimax' as never, 'fixture-key'), /invalid_tts_key/);
    for (const cursor of ['', '\u0000', 'x'.repeat(2049), '\ud800']) await assert.rejects(client.listElevenLabsVoices(cursor), /invalid_tts_cursor/);
    assert.equal(calls, 0);
  } finally { controller.stop(); }
});

test('secret is not persisted, returned or propagated even if transport or response reflects it', async () => {
  const { controller } = await setup(); let mode = 0, calls = 0; const secret = 'fixture-sensitive-value';
  const client = new TtsSettingsClient(controller, fake(async (_path, init) => {
    calls++; assert.equal(JSON.parse(String(init?.body)).apiKey, secret);
    if (mode === 0) throw Error(`transport failure ${secret}`);
    if (mode === 1) return Response.json({ ...initial(), configured: { alibaba: true, bytedance: false, elevenlabs: false }, voices: { ...initial().voices, alibaba: secret } });
    return Response.json({ error: { code: 'invalid_tts_key', message: secret } }, { status: 400 });
  }));
  try {
    for (mode = 0; mode < 3; mode++) { const result = await client.setKey('alibaba', secret); assert.deepEqual(result, { state: ['unknown', 'saved', 'invalid_tts_key'][mode] }); assert.ok(!JSON.stringify(result).includes(secret)); }
    assert.equal(calls, 3); assert.ok(!JSON.stringify(client).includes(secret));
  } finally { controller.stop(); }
});

test('known busy and invalid responses are distinct; uncertain writes never retry', async () => {
  const { controller } = await setup(); let mode = 0, calls = 0;
  const client = new TtsSettingsClient(controller, fake(async () => { calls++; if (mode === 0) return Response.json({ error: { code: 'tts_settings_busy' } }, { status: 409 }); if (mode === 1) return Response.json({ error: { code: 'invalid_tts_settings' } }, { status: 400 }); if (mode === 2) return new Response(null, { status: 401 }); if (mode === 3) return Response.json({}, { status: 503 }); return Response.json(initial()); }));
  try {
    for (mode = 0; mode < 5; mode++) assert.equal((await client.save({ provider: 'elevenlabs', voice: 'new', speed: null })).state, ['tts_settings_busy', 'invalid_tts_settings', 'unknown', 'unknown', 'unknown'][mode]);
    assert.equal(calls, 5);
  } finally { controller.stop(); }
});

test('read and list validate response schema, auth, status and bounds without exposing response body', async () => {
  const { controller } = await setup(); let status = 200, body: unknown = initial();
  const client = new TtsSettingsClient(controller, fake(async () => Response.json(body, { status })));
  try {
    for (const bad of [{ ...initial(), extra: 'secret' }, { ...initial(), voices: { ...initial().voices, minimax: 'x'.repeat(513) } }, { ...initial(), speeds: { minimax: 10, bytedance: null } }, { ...initial(), configured: { ...initial().configured, alibaba: 'secret' } }]) { body = bad; await assert.rejects(client.load(), /invalid_tts_response/); }
    status = 401; await assert.rejects(client.load(), /access_denied/); status = 404; await assert.rejects(client.load(), /tts_unsupported/); status = 200;
    for (const bad of [{ voices: [], nextCursor: null, extra: 1 }, { voices: Array.from({ length: 101 }, () => ({ id: 'x', name: 'y' })), nextCursor: null }, { voices: [{ id: '', name: 'name' }], nextCursor: null }, { voices: [], nextCursor: '\u0000' }]) { body = bad; await assert.rejects(client.listElevenLabsVoices(), /invalid_tts_response/); }
    status = 400; body = { error: { code: 'tts_key_required' } }; await assert.rejects(client.listElevenLabsVoices(), /tts_key_required/);
  } finally { controller.stop(); }
});

test('latest reads supersede older reads and same controller serializes key/selection writes', async () => {
  const { controller } = await setup(); const one = deferred<Response>(), two = deferred<Response>(), post = deferred<Response>(); let gets = 0, writes = 0;
  const transport = fake(async (_path, init) => { if (init?.method === 'POST') { writes++; return post.promise; } return [one, two][gets++].promise; });
  const a = new TtsSettingsClient(controller, transport), b = new TtsSettingsClient(controller, transport);
  try {
    const old = a.load(), fresh = b.load(); two.resolve(Response.json(initial())); await fresh; one.resolve(Response.json(initial())); await assert.rejects(old, /tts_superseded/);
    const saving = a.setKey('alibaba', 'fixture-key'); await assert.rejects(b.save({ provider: 'minimax', voice: 'v', speed: null }), /tts_write_pending/); await assert.rejects(b.load(), /tts_write_pending/); await assert.rejects(b.listElevenLabsVoices(), /tts_write_pending/);
    post.resolve(Response.json({ ...initial(), configured: { alibaba: true, bytedance: false, elevenlabs: false } })); assert.deepEqual(await saving, { state: 'saved' }); assert.equal(writes, 1);
  } finally { controller.stop(); }
});

test('A→B→A, disconnect and disposal discard read/list and make dispatched writes unknown', async () => {
  const { controller, initialView, change, disconnect } = await setup(); const read = deferred<Response>(), write = deferred<Response>(); let calls = 0;
  const client = new TtsSettingsClient(controller, fake(async (_path, init) => { calls++; return init?.method === 'POST' ? write.promise : read.promise; }));
  try {
    const pendingRead = client.load(); change({ ...initialView, sessionId: 'B' }); change(initialView); read.resolve(Response.json(initial())); await assert.rejects(pendingRead, /session_changed/); assert.equal(client.current(), false);
    const next = new TtsSettingsClient(controller, fake(async () => { calls++; return write.promise; })); const pendingWrite = next.setKey('elevenlabs', 'fixture-key'); disconnect(Error('offline')); write.resolve(Response.json(initial())); assert.equal((await pendingWrite).state, 'unknown'); assert.equal(calls, 2); next.dispose();
  } finally { controller.stop(); }
});

test('native and web requests retain existing authentication and forbid redirects', async t => {
  const native = await setup('https://fixture.invalid'); const requests: { init?: RequestInit }[] = [];
  const fetcher: typeof fetch = async (_url, init) => { requests.push({ init }); return Response.json(init?.method === 'POST' ? { ...initial(), configured: { alibaba: true, bytedance: false, elevenlabs: false } } : initial()); };
  const transport = nativeTransport('https://fixture.invalid', { async tokenFor() { return 'fixture-token'; } } as never, fetcher);
  try { const client = new TtsSettingsClient(native.controller, transport); await client.load(); await client.setKey('alibaba', 'fixture-key'); for (const call of requests) { assert.equal(call.init?.redirect, 'error'); assert.equal(call.init?.credentials, 'omit'); assert.equal(new Headers(call.init?.headers).get('authorization'), 'Bearer fixture-token'); } } finally { native.controller.stop(); }
  const old = Object.getOwnPropertyDescriptor(globalThis, 'window'); t.after(() => { if (old) Object.defineProperty(globalThis, 'window', old); else Reflect.deleteProperty(globalThis, 'window'); }); Object.defineProperty(globalThis, 'window', { configurable: true, value: { location: { origin: 'https://fixture.invalid' } } }); t.mock.method(globalThis, 'fetch', fetcher);
  const web = await setup('https://fixture.invalid'); try { const client = new TtsSettingsClient(web.controller, webTransport('https://fixture.invalid')); await client.load(); await client.setKey('alibaba', 'fixture-key'); for (const call of requests.slice(2)) { assert.equal(call.init?.redirect, 'error'); assert.equal(call.init?.credentials, 'same-origin'); assert.equal(new Headers(call.init?.headers).get('authorization'), null); } } finally { web.controller.stop(); }
});

test('a newer list or write invalidates old list results; disposition cannot revive the client', async () => {
  const { controller } = await setup(); const one = deferred<Response>(), two = deferred<Response>(), three = deferred<Response>(); let count = 0;
  const client = new TtsSettingsClient(controller, fake(async (_path, init) => init?.method === 'POST' ? Response.json(initial()) : [one, two, three][count++].promise));
  try {
    const old = client.listElevenLabsVoices(), fresh = client.listElevenLabsVoices();
    two.resolve(Response.json({ voices: [{ id: 'new', name: 'New' }], nextCursor: null })); assert.equal((await fresh).voices[0].id, 'new');
    one.resolve(Response.json({ voices: [{ id: 'old', name: 'Old' }], nextCursor: null })); await assert.rejects(old, /tts_superseded/);
    const pending = client.listElevenLabsVoices(); const saved = await client.save({ provider: 'minimax', voice: 'fixture-voice', speed: null }); assert.equal(saved.state, 'saved');
    three.resolve(Response.json({ voices: [], nextCursor: null })); await assert.rejects(pending, /tts_superseded/);
    client.dispose(); assert.equal(client.current(), false); await assert.rejects(client.load(), /session_changed/);
  } finally { controller.stop(); }
});

test('response limits, redirected or malformed replies, and test-seed unsupported never expose data', async () => {
  const { controller } = await setup(); let mode = 0;
  const client = new TtsSettingsClient(controller, fake(async (_path, init) => {
    if (init?.method === 'POST') {
      if (mode === 0) return Response.json({ error: { code: 'tts_unsupported' } }, { status: 404 });
      return new Response('x'.repeat(65537), { headers: { 'content-type': 'application/json' } });
    }
    if (mode === 2) return new Response('x'.repeat(65537), { headers: { 'content-type': 'application/json' } });
    return new Response('{}', { status: 302, headers: { location: 'https://external.invalid' } });
  }));
  try {
    assert.deepEqual(await client.setKey('elevenlabs', 'fixture-key'), { state: 'tts_unsupported' });
    mode = 1; assert.deepEqual(await client.setKey('elevenlabs', 'fixture-key'), { state: 'unknown' });
    mode = 2; await assert.rejects(client.load(), /invalid_tts_response/);
    mode = 3; await assert.rejects(client.load(), /tts_unavailable/);
  } finally { controller.stop(); }
});

test('proved invalid body and method-not-allowed are distinguished for both writes', async () => {
  const { controller } = await setup(); let status = 400, code = 'invalid_tts_settings';
  const client = new TtsSettingsClient(controller, fake(async () => Response.json({ error: { code } }, { status })));
  try {
    assert.deepEqual(await client.setKey('alibaba', 'fixture-key'), { state: 'invalid_tts_settings' });
    status = 405; code = 'method_not_allowed';
    assert.deepEqual(await client.setKey('alibaba', 'fixture-key'), { state: 'tts_unsupported' });
    assert.deepEqual(await client.save({ provider: 'minimax', voice: 'voice', speed: null }), { state: 'tts_unsupported' });
  } finally { controller.stop(); }
});

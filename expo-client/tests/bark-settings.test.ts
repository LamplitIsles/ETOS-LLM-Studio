import { test } from 'node:test';
import assert from 'node:assert/strict';
import { BarkSettingsClient } from '../src/cfl/bark-settings';
import { ChatController, type ChatPort } from '../src/cfl/chat';
import { nativeTransport, webTransport, type ApiTransport } from '../src/cfl/transport';
import { createFixture } from './fixtures/fixture';
import type { ChatView } from '../vendor/contracts/src/index';

function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(r => { resolve = r; }); return { promise, resolve }; }
const fake = (request: ApiTransport['request']): ApiTransport => ({ origin: 'fixture://local', async read() { throw Error('unused'); }, request });
async function setup(origin = 'fixture://local') {
  const fixture = createFixture(), initial = fixture.read(); let change = (_: ChatView) => {}; let disconnect = (_: Error) => {};
  const controller = new ChatController(origin, async () => ({ close() {} }) as WebSocket, { async load() { return []; }, async save() {} }, () => 'unused', async (_, changed, offline) => { change = changed; disconnect = offline; changed(initial); return fixture.port as ChatPort; });
  await controller.start(); return { controller, initial, change: (v: ChatView) => change(v), disconnect: () => disconnect(Error('offline')) };
}

test('fake server models first set, replacement preserving disabled, enable, disable and remove', async () => {
  const { controller } = await setup(); let configured = false, enabled = false, calls = 0;
  const client = new BarkSettingsClient(controller, fake(async (path, init) => {
    calls++; assert.equal(path, '/api/bark/settings');
    if (init?.method === 'POST') {
      assert.equal(new Headers(init.headers).get('content-type'), 'application/json');
      const body = JSON.parse(String(init.body));
      if (body.action === 'set') { if (!configured) enabled = true; configured = true; }
      if (body.action === 'enable') enabled = true;
      if (body.action === 'disable') enabled = false;
      if (body.action === 'remove') { configured = false; enabled = false; }
    } else assert.equal(init?.cache, 'no-store');
    return Response.json({ configured, enabled });
  }));
  try {
    assert.deepEqual(await client.load(), { configured: false, enabled: false });
    assert.deepEqual(await client.update({ action: 'set', key: 'fake-key' }), { state: 'saved', snapshot: { configured: true, enabled: true } });
    assert.equal((await client.update({ action: 'disable' })).state, 'saved');
    assert.deepEqual(await client.update({ action: 'set', key: 'fake-replacement' }), { state: 'saved', snapshot: { configured: true, enabled: false } });
    assert.deepEqual(await client.update({ action: 'enable' }), { state: 'saved', snapshot: { configured: true, enabled: true } });
    assert.deepEqual(await client.update({ action: 'remove' }), { state: 'saved', snapshot: { configured: false, enabled: false } });
    assert.equal(calls, 6);
  } finally { client.dispose(); controller.stop(); }
});

test('invalid actions never dispatch and never expose supplied data', async () => {
  const { controller } = await setup(); let calls = 0;
  const client = new BarkSettingsClient(controller, fake(async () => { calls++; return Response.json({}); }));
  try {
    for (const value of [null, {}, { action: 'no' }, { action: 'enable', key: 'fake-secret' }, { action: 'set' }, { action: 'set', key: '' }, { action: 'set', key: 'a b' }, { action: 'set', key: 'a\n' }, { action: 'set', key: 'a'.repeat(513) }, { action: 'set', key: 'fake-secret', extra: 1 }]) assert.deepEqual(await client.update(value as never), { state: 'invalid' });
    assert.equal(calls, 0); assert.ok(!JSON.stringify(client).includes('fake-secret'));
  } finally { controller.stop(); }
});

test('auth and unsupported statuses are distinguished on reads and writes; uncertain writes do not retry', async () => {
  const { controller } = await setup(); let status = 200, calls = 0, throws = false;
  const client = new BarkSettingsClient(controller, fake(async () => { calls++; if (throws) throw Error('fake-secret'); return new Response(null, { status }); }));
  try {
    for (status of [401, 403]) { await assert.rejects(client.load(), { message: 'access_denied' }); assert.deepEqual(await client.update({ action: 'disable' }), { state: 'unknown' }); }
    for (status of [404, 405, 501]) { await assert.rejects(client.load(), { message: 'unsupported' }); assert.deepEqual(await client.update({ action: 'disable' }), { state: 'unsupported' }); }
    for (const [s, state] of [[400, 'invalid'], [409, 'busy'], [500, 'unknown']] as const) { status = s; assert.deepEqual(await client.update({ action: 'disable' }), { state }); }
    throws = true; assert.deepEqual(await client.update({ action: 'set', key: 'fake-secret' }), { state: 'unknown' }); await assert.rejects(client.load(), { message: 'bark_unavailable' });
    assert.equal(calls, 15);
  } finally { controller.stop(); }
});

test('reject malformed, excessive, leaking and contradictory snapshots without exposing response data', async () => {
  const { controller } = await setup(); let reply: () => Response = () => Response.json({});
  const client = new BarkSettingsClient(controller, fake(async () => reply()));
  try {
    for (const body of [null, [], {}, { configured: true, enabled: 'fake-secret' }, { configured: false, enabled: true }, { configured: true, enabled: false, key: 'fake-secret' }]) {
      reply = () => Response.json(body); await assert.rejects(client.load(), { message: 'invalid_bark_response' }); assert.deepEqual(await client.update({ action: 'set', key: 'fake-secret' }), { state: 'unknown' });
    }
    for (const response of [() => new Response('x'.repeat(65537), { headers: { 'content-type': 'application/json' } }), () => new Response('fake-secret', { headers: { 'content-type': 'text/plain' } }), () => new Response('{', { headers: { 'content-type': 'application/json' } })]) {
      reply = response; await assert.rejects(client.load(), { message: 'invalid_bark_response' }); assert.deepEqual(await client.update({ action: 'set', key: 'fake-secret' }), { state: 'unknown' });
    }
    reply = () => Response.json({ configured: false, enabled: false }); assert.deepEqual(await client.update({ action: 'set', key: 'fake-secret' }), { state: 'unknown' });
    reply = () => Response.json({ configured: true, enabled: false }); assert.deepEqual(await client.update({ action: 'enable' }), { state: 'unknown' }); assert.deepEqual(await client.update({ action: 'remove' }), { state: 'unknown' });
    reply = () => Response.json({ configured: true, enabled: true }); assert.deepEqual(await client.update({ action: 'disable' }), { state: 'unknown' });
  } finally { controller.stop(); }
});

test('overlapping reads, writes and disposed or changed scope discard late replies', async () => {
  const { controller, initial, change, disconnect } = await setup(); const a = deferred<Response>(), b = deferred<Response>(), post = deferred<Response>(); let reads = 0, writes = 0;
  const transport = fake(async (_path, init) => { if (init?.method === 'POST') { writes++; return post.promise; } return [a, b][reads++].promise; });
  const first = new BarkSettingsClient(controller, transport), second = new BarkSettingsClient(controller, transport);
  try {
    const old = first.load(), fresh = second.load(); b.resolve(Response.json({ configured: true, enabled: false })); await fresh; a.resolve(Response.json({ configured: false, enabled: false })); await assert.rejects(old, { message: 'bark_superseded' });
    const pending = first.update({ action: 'set', key: 'fake-secret' }); assert.deepEqual(await second.update({ action: 'disable' }), { state: 'busy' }); await assert.rejects(second.load(), { message: 'bark_write_pending' });
    change({ ...initial, sessionId: 'other' }); change(initial); post.resolve(Response.json({ configured: true, enabled: true })); assert.deepEqual(await pending, { state: 'unknown' }); assert.equal(writes, 1); assert.equal(first.current(), false); assert.equal(second.current(), false);
    const late = deferred<Response>(), next = new BarkSettingsClient(controller, fake(async () => late.promise)); const loading = next.load(); disconnect(); late.resolve(Response.json({ configured: false, enabled: false })); await assert.rejects(loading, { message: 'session_changed' });
    next.dispose(); assert.equal(next.current(), false);
  } finally { controller.stop(); }
});

test('transport retains native and web authentication and redirect protections', async t => {
  const requests: RequestInit[] = [];
  const fetcher: typeof fetch = async (_url, init) => { requests.push(init ?? {}); return Response.json({ configured: true, enabled: true }); };
  const native = await setup('https://fixture.invalid');
  try { const client = new BarkSettingsClient(native.controller, nativeTransport('https://fixture.invalid', { async tokenFor() { return 'fake-token'; } } as never, fetcher)); await client.load(); await client.update({ action: 'set', key: 'fake-key' }); } finally { native.controller.stop(); }
  const old = Object.getOwnPropertyDescriptor(globalThis, 'window'); t.after(() => { if (old) Object.defineProperty(globalThis, 'window', old); else Reflect.deleteProperty(globalThis, 'window'); });
  Object.defineProperty(globalThis, 'window', { configurable: true, value: { location: { origin: 'https://fixture.invalid' } } }); t.mock.method(globalThis, 'fetch', fetcher);
  const web = await setup('https://fixture.invalid');
  try { const client = new BarkSettingsClient(web.controller, webTransport('https://fixture.invalid')); await client.load(); await client.update({ action: 'set', key: 'fake-key' }); } finally { web.controller.stop(); }
  for (const [index, init] of requests.entries()) { assert.equal(init.redirect, 'error'); assert.equal(init.credentials, index < 2 ? 'omit' : 'same-origin'); assert.equal(new Headers(init.headers).get('authorization'), index < 2 ? 'Bearer fake-token' : null); }
});

test('construction and active scope are bound permanently; redirected replies are untrusted', async () => {
  const { controller } = await setup(); let active = true;
  try {
    assert.throws(() => new BarkSettingsClient(controller, { ...fake(async () => Response.json({})), origin: 'https://other.invalid' }), { message: 'origin_mismatch' });
    assert.throws(() => new BarkSettingsClient(controller, fake(async () => Response.json({})), () => false), { message: 'offline' });
    const response = () => { const r = Response.json({ configured: true, enabled: true }); Object.defineProperty(r, 'redirected', { value: true }); return r; };
    const client = new BarkSettingsClient(controller, fake(async () => response()), () => active);
    await assert.rejects(client.load(), { message: 'bark_unavailable' }); assert.deepEqual(await client.update({ action: 'set', key: 'fake-key' }), { state: 'unknown' });
    active = false; assert.equal(client.current(), false); active = true; assert.equal(client.current(), false); await assert.rejects(client.load(), { message: 'session_changed' });
  } finally { controller.stop(); }
});

test('a write supersedes an in-flight read even if that read succeeds later', async () => {
  const { controller } = await setup(); const read = deferred<Response>();
  const client = new BarkSettingsClient(controller, fake(async (_path, init) => init?.method === 'POST' ? Response.json({ configured: true, enabled: true }) : read.promise));
  try {
    const old = client.load(); assert.equal((await client.update({ action: 'set', key: 'fake-key' })).state, 'saved');
    read.resolve(Response.json({ configured: false, enabled: false })); await assert.rejects(old, { message: 'bark_superseded' });
  } finally { controller.stop(); }
});

test('authorization lost after a committed write is unknown and never retried', async () => {
  const { controller } = await setup(); let enabled = false, writes = 0, status = 401;
  const client = new BarkSettingsClient(controller, fake(async (_path, init) => {
    if (init?.method === 'POST') { writes++; enabled = !enabled; return new Response(null, { status }); }
    return Response.json({ configured: true, enabled });
  }));
  try {
    for (status of [401, 403]) {
      const before = writes; assert.deepEqual(await client.update({ action: enabled ? 'disable' : 'enable' }), { state: 'unknown' });
      assert.equal(writes, before + 1); assert.equal((await client.load()).enabled, enabled); assert.equal(writes, before + 1);
    }
  } finally { controller.stop(); }
});

test('explicit test sends an empty JSON object and classifies only trusted CFL replies', async () => {
  const { controller } = await setup(); let calls = 0, response: () => Response = () => Response.json({ status: 'accepted' });
  const client = new BarkSettingsClient(controller, fake(async (path, init) => {
    calls++; assert.equal(path, '/api/bark/test'); assert.equal(init?.method, 'POST'); assert.equal(init?.body, '{}'); assert.equal(new Headers(init?.headers).get('content-type'), 'application/json'); return response();
  }));
  const error = (status: number, code: string, message = 'fake-secret') => () => Response.json({ error: { code, message } }, { status });
  try {
    for (const [reply, state] of [
      [() => Response.json({ status: 'accepted' }), 'accepted'],
      [error(409, 'bark_not_configured'), 'bark_not_configured'],
      [error(409, 'bark_disabled'), 'bark_disabled'],
      [error(502, 'bark_upstream_rejected'), 'bark_upstream_rejected'],
      [error(504, 'outcome_unknown'), 'unknown'],
      ...[401, 403, 500].map(status => [() => new Response(null, { status }), 'unknown']),
      ...[404, 405, 501].map(status => [() => new Response(null, { status }), 'unsupported']),
      [() => Response.json({ status: 'accepted', secret: 'fake-secret' }), 'unknown'],
      [() => Response.json({ status: 'accepted' }, { status: 201 }), 'unknown'],
      [() => Response.json({ status: 'pending' }), 'unknown'],
      [error(409, 'bark_upstream_rejected'), 'unknown'],
      [error(502, 'bark_disabled'), 'unknown'],
      [() => Response.json({ error: { code: 'bark_disabled', message: 'fake-secret', extra: true } }, { status: 409 }), 'unknown'],
      [() => Response.json({ error: { code: 'bark_disabled' } }, { status: 409 }), 'unknown'],
      [() => new Response('fake-secret', { status: 409 }), 'unknown'],
      [() => new Response('x'.repeat(65537), { headers: { 'content-type': 'application/json' } }), 'unknown'],
      [() => { const r = Response.json({ status: 'accepted' }); Object.defineProperty(r, 'redirected', { value: true }); return r; }, 'unknown'],
    ] as [() => Response, string][]) {
      response = reply; const previous = calls; const result = await client.testNotification(); assert.deepEqual(result, { state }); assert.equal(calls, previous + 1); assert.ok(!JSON.stringify(result).includes('fake-secret'));
    }
    const failing = new BarkSettingsClient(controller, fake(async () => { calls++; throw Error('fake-secret'); }));
    const previous = calls; assert.deepEqual(await failing.testNotification(), { state: 'unknown' }); assert.equal(calls, previous + 1);
  } finally { controller.stop(); }
});

test('test requests serialize with settings across clients and invalidate stale reads', async () => {
  const { controller } = await setup(); const read = deferred<Response>(), testReply = deferred<Response>(), write = deferred<Response>(); let sent = 0;
  const transport = fake(async (path, init) => {
    sent++; if (path === '/api/bark/test') return testReply.promise;
    return init?.method === 'POST' ? write.promise : read.promise;
  });
  const a = new BarkSettingsClient(controller, transport), b = new BarkSettingsClient(controller, transport);
  try {
    const old = a.load(), pendingTest = b.testNotification();
    assert.deepEqual(await a.testNotification(), { state: 'busy' }); assert.deepEqual(await a.update({ action: 'disable' }), { state: 'busy' }); await assert.rejects(a.load(), { message: 'bark_write_pending' });
    read.resolve(Response.json({ configured: false, enabled: false })); await assert.rejects(old, { message: 'bark_superseded' });
    testReply.resolve(Response.json({ status: 'accepted' })); assert.deepEqual(await pendingTest, { state: 'accepted' });
    const pendingWrite = a.update({ action: 'disable' }); assert.deepEqual(await b.testNotification(), { state: 'busy' });
    write.resolve(Response.json({ configured: true, enabled: false })); assert.equal((await pendingWrite).state, 'saved'); assert.equal(sent, 3);
  } finally { controller.stop(); }
});

test('scope loss before or after test dispatch yields unknown without retry', async () => {
  const { controller, initial, change } = await setup(); const response = deferred<Response>(); let calls = 0;
  const client = new BarkSettingsClient(controller, fake(async () => { calls++; return response.promise; }));
  try {
    const pending = client.testNotification(); change({ ...initial, sessionId: 'other' }); change(initial);
    response.resolve(Response.json({ status: 'accepted' })); assert.deepEqual(await pending, { state: 'unknown' });
    assert.deepEqual(await client.testNotification(), { state: 'unknown' }); assert.equal(calls, 1);
  } finally { controller.stop(); }
});

test('scope disposal while reading a test response discards acceptance', async () => {
  const { controller } = await setup(); const gate = deferred<Uint8Array>(); let calls = 0;
  const stream = new ReadableStream<Uint8Array>({ async pull(controller) { controller.enqueue(await gate.promise); controller.close(); } });
  const client = new BarkSettingsClient(controller, fake(async () => { calls++; return new Response(stream, { headers: { 'content-type': 'application/json' } }); }));
  try {
    const pending = client.testNotification(); await Promise.resolve(); client.dispose(); gate.resolve(new TextEncoder().encode('{"status":"accepted"}'));
    assert.deepEqual(await pending, { state: 'unknown' }); assert.equal(calls, 1);
  } finally { controller.stop(); }
});

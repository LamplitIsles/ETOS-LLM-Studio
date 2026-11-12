import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ChatController } from '../src/cfl/chat';
import { createChatHost, type ChatBackend, type ChatChange } from '../vendor/contracts/src/server';
import type { ChatView } from '../vendor/contracts/src/index';

const activeView: ChatView = { version: 2, sessionId: 'session-A', name: 'test', activeTurnId: 'turn-A', contextUsage: { tokens: null, capacity: null }, compaction: null, messages: [], before: null, capabilities: { text: true, steer: true, stop: true, images: false } };

test('controller stops the active turn over the real chat protocol exactly once', async () => {
  const scope = Symbol(); const calls: string[] = [];
  const backend = { async read() { return activeView; }, subscribe(_changed: (change: ChatChange) => void) { return { scope, close() {} }; },
    async stop(id: string) { calls.push(id); return { stopped: true }; } } as unknown as ChatBackend;
  const host = await createChatHost(backend, error => { throw error; });
  class Socket extends EventTarget {
    readyState = 1;
    peer!: ReturnType<typeof host.connect>;
    send(data: string) { void this.peer.receive(data); }
    close() { if (this.readyState === 3) return; this.readyState = 3; this.dispatchEvent(new Event('close')); }
  }
  const socket = new Socket();
  socket.peer = host.connect({ send(data) { queueMicrotask(() => socket.dispatchEvent(new MessageEvent('message', { data }))); }, close() { socket.close(); } }, async () => true);
  const controller = new ChatController('fixture://local', async () => socket as unknown as WebSocket,
    { async load() { return []; }, async save() {} }, () => 'unused');
  try {
    await controller.start();
    const target = controller.captureStopTarget(controller.snapshot());
    assert.ok(target);
    assert.equal(await controller.stopTurn(target), 'stopped');
    assert.deepEqual(calls, ['turn-A']);
  } finally { controller.stop(); host.close(); }
});

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: Error) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

async function withPort(stop?: (id: string) => Promise<{ stopped: boolean }>) {
  let changed!: (view: ChatView) => void;
  let offline!: (error: Error) => void;
  const controller = new ChatController('fixture://local', async () => ({ close() {} }) as WebSocket,
    { async load() { return []; }, async save() {} }, () => 'unused', async (_, update, disconnected) => {
      changed = update; offline = disconnected; update(activeView);
      return { async history() { return { messages: [], before: null }; }, async submit() { throw Error('unused'); },
        async lookup() { return null; }, close() {}, ...(stop ? { stop } : {}) };
    });
  await controller.start();
  return { controller, changed: (value: ChatView) => changed(value), offline: () => offline(Error('disconnected')) };
}

function target(controller: ChatController) {
  const value = controller.captureStopTarget(controller.snapshot());
  assert.ok(value);
  return value;
}

test('target is bound to the actual snapshot, controller, session and active-turn generation', async () => {
  let calls = 0;
  const h = await withPort(async () => { calls++; return { stopped: true }; });
  const other = await withPort();
  try {
    const snap = h.controller.snapshot(), old = target(h.controller);
    h.changed({ ...activeView, name: 'updated' });
    assert.equal(h.controller.captureStopTarget(snap), null);
    assert.equal(await other.controller.stopTurn(old), 'stale');
    h.changed({ ...activeView, sessionId: 'session-B' }); h.changed(activeView);
    assert.equal(await h.controller.stopTurn(old), 'stale');
    const oldTurn = target(h.controller);
    h.changed({ ...activeView, activeTurnId: 'turn-B' }); h.changed(activeView);
    assert.equal(await h.controller.stopTurn(oldTurn), 'stale');
    const current = target(h.controller); h.controller.stop();
    assert.equal(await h.controller.stopTurn(current), 'stale');
    assert.equal(calls, 0);
  } finally { h.controller.stop(); other.controller.stop(); }
});

test('pre-dispatch turn, connection and capability changes never call stop', async () => {
  let calls = 0;
  const h = await withPort(async () => { calls++; return { stopped: true }; });
  try {
    const a = target(h.controller), pending = h.controller.stopTurn(a);
    h.changed({ ...activeView, activeTurnId: 'turn-B' });
    assert.equal(await pending, 'stale');
    h.changed(activeView);
    const b = target(h.controller), pendingOffline = h.controller.stopTurn(b);
    h.offline(); assert.equal(await pendingOffline, 'offline');
    assert.equal(calls, 0);
  } finally { h.controller.stop(); }
  const unavailable = await withPort();
  try { assert.equal(await unavailable.controller.stopTurn(target(unavailable.controller)), 'unavailable'); }
  finally { unavailable.controller.stop(); }
  const disabled = await withPort(async () => { calls++; return { stopped: true }; });
  try {
    const disabledView = { ...activeView, capabilities: { ...activeView.capabilities, stop: false } } as unknown as ChatView;
    disabled.changed(disabledView);
    assert.equal(await disabled.controller.stopTurn(target(disabled.controller)), 'unavailable');
    assert.equal(calls, 0);
  } finally { disabled.controller.stop(); }
});

test('concurrent requests share one invocation; unknown is sticky per handle and a new explicit target is a new action', async () => {
  const first = deferred<{ stopped: boolean }>(); let calls = 0;
  const h = await withPort(async () => { calls++; return calls === 1 ? first.promise : { stopped: false }; });
  try {
    const a = target(h.controller), b = target(h.controller);
    const x = h.controller.stopTurn(a), y = h.controller.stopTurn(a), z = h.controller.stopTurn(b);
    await Promise.resolve(); assert.equal(calls, 1);
    first.reject(Error('lost response'));
    assert.deepEqual(await Promise.all([x, y, z]), ['unknown', 'unknown', 'unknown']);
    assert.equal(await h.controller.stopTurn(a), 'unknown');
    assert.equal(await h.controller.stopTurn(b), 'unknown'); assert.equal(calls, 1);
    // This is a separate explicit user action, not a retry scheduled by the controller.
    assert.equal(await h.controller.stopTurn(target(h.controller)), 'not_stopped');
    assert.equal(calls, 2);
    h.changed({ ...activeView, activeTurnId: 'turn-B' }); h.changed(activeView);
    assert.equal(await h.controller.stopTurn(a), 'stale'); assert.equal(calls, 2);
  } finally { h.controller.stop(); }
});

test('late result after A→B→A, disconnect, or controller stop is unknown and never changes the new view', async () => {
  for (const kind of ['session', 'disconnect', 'stop'] as const) {
    const request = deferred<{ stopped: boolean }>(); let calls = 0;
    const h = await withPort(async () => { calls++; return request.promise; });
    try {
      const old = target(h.controller), pending = h.controller.stopTurn(old);
      await Promise.resolve(); assert.equal(calls, 1);
      if (kind === 'session') { h.changed({ ...activeView, sessionId: 'session-B' }); h.changed(activeView); }
      else if (kind === 'disconnect') h.offline();
      else h.controller.stop();
      const snapshot = h.controller.snapshot();
      request.resolve({ stopped: true }); assert.equal(await pending, 'unknown');
      assert.equal(h.controller.snapshot(), snapshot);
      if (kind !== 'disconnect') assert.equal(await h.controller.stopTurn(old), 'stale');
      else assert.equal(await h.controller.stopTurn(old), 'unknown');
      assert.equal(calls, 1);
    } finally { h.controller.stop(); }
  }
});

test('pending request blocks a different turn, and malformed or rejected responses are unknown', async () => {
  const first = deferred<{ stopped: boolean }>(); let calls = 0;
  const h = await withPort(async () => { calls++; if (calls === 1) return first.promise; if (calls === 2) return { stopped: 'yes' } as unknown as { stopped: boolean }; throw Error('rejected'); });
  try {
    const pending = h.controller.stopTurn(target(h.controller)); await Promise.resolve();
    h.changed({ ...activeView, activeTurnId: 'turn-B' });
    assert.equal(await h.controller.stopTurn(target(h.controller)), 'unavailable');
    first.resolve({ stopped: true }); assert.equal(await pending, 'stopped');
    assert.equal(await h.controller.stopTurn(target(h.controller)), 'unknown');
    assert.equal(await h.controller.stopTurn(target(h.controller)), 'unknown');
    assert.equal(calls, 3);
  } finally { h.controller.stop(); }
});

test('real protocol distinguishes not-stopped from lost response and never replays after close', async () => {
  const scope = Symbol(), started = deferred<void>(), held = deferred<{ stopped: boolean }>();
  const calls: string[] = [];
  const backend = { async read() { return activeView; }, subscribe(_changed: (change: ChatChange) => void) { return { scope, close() {} }; },
    async stop(id: string) { calls.push(id); if (calls.length === 1) return { stopped: false }; started.resolve(); return held.promise; } } as unknown as ChatBackend;
  const host = await createChatHost(backend, () => {});
  class Socket extends EventTarget {
    readyState = 1;
    peer!: ReturnType<typeof host.connect>;
    send(data: string) { void this.peer.receive(data); }
    close() { if (this.readyState === 3) return; this.readyState = 3; this.dispatchEvent(new Event('close')); }
  }
  const socket = new Socket();
  socket.peer = host.connect({ send(data) { if (socket.readyState === 1) queueMicrotask(() => socket.dispatchEvent(new MessageEvent('message', { data }))); }, close() { socket.close(); } }, async () => true);
  const controller = new ChatController('fixture://local', async () => socket as unknown as WebSocket,
    { async load() { return []; }, async save() {} }, () => 'unused');
  try {
    await controller.start();
    assert.equal(await controller.stopTurn(target(controller)), 'not_stopped');
    const second = target(controller), pending = controller.stopTurn(second);
    await started.promise; socket.close();
    assert.equal(await pending, 'unknown');
    held.resolve({ stopped: true });
    assert.equal(await controller.stopTurn(second), 'unknown');
    assert.deepEqual(calls, ['turn-A', 'turn-A']);
  } finally { controller.stop(); held.resolve({ stopped: true }); host.close(); }
});

test('reconnect never replays an unknown stop and old targets cannot operate on the new connection', async () => {
  const first = deferred<{ stopped: boolean }>(); let calls = 0;
  const h = await withPort(async () => { calls++; return first.promise; });
  try {
    const old = target(h.controller), pending = h.controller.stopTurn(old);
    await Promise.resolve(); assert.equal(calls, 1);
    h.offline(); await h.controller.start();
    first.resolve({ stopped: true }); assert.equal(await pending, 'unknown');
    assert.equal(await h.controller.stopTurn(old), 'stale');
    await Promise.resolve(); assert.equal(calls, 1);
  } finally { h.controller.stop(); }
});

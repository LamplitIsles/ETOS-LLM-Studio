import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ChatController, type ChatPort, type Pending } from '../src/cfl/chat';
import { rowsFor, visibleRowsFor } from '../src/ui/timelineRows';
import { createChatHost, type ChatBackend, type ChatChange } from '../vendor/contracts/src/server';
import type { ChatMessage, ChatView } from '../vendor/contracts/src/index';

const message = (n: number): ChatMessage => ({ id: `m${n}`, role: 'user', text: `message ${n}`, createdAt: n, operationId: null, turnId: null });
const view = (messages: ChatMessage[], before: string | null = null): ChatView => ({ version: 2, sessionId: 'fixture', name: 'test', activeTurnId: null, contextUsage: { tokens: null, capacity: null }, compaction: null, messages, before, capabilities: { text: true, steer: true, stop: true, images: false } });

async function setup(initial: ChatView, pages: Record<string, { messages: ChatMessage[]; before: string | null }> = {}, entries: Pending[] = []) {
  let scope = Symbol('test'); let changed!: (event: ChatChange) => void;
  const requests: string[] = [];
  const backend = {
    async read() { return initial; },
    subscribe(fn: typeof changed) { changed = fn; return { scope, close() {} }; },
    async history(before: string) { requests.push(before); return pages[before] ?? { messages: [], before: null }; },
    async submit(input: { operationId: string }) { return { operationId: input.operationId, attempt: 1, state: 'submitted', messageId: 'confirmed', turnId: null, error: null }; },
    async lookup() { return null; },
  } as unknown as ChatBackend;
  const host = await createChatHost(backend, error => { throw error; });
  class Socket extends EventTarget {
    readyState = 1; peer!: ReturnType<typeof host.connect>;
    send(data: string) { void this.peer.receive(data); }
    close() { if (this.readyState === 3) return; this.readyState = 3; this.dispatchEvent(new Event('close')); }
  }
  let socket!: Socket;
  const controller = new ChatController('fixture://memory', async () => {
    socket = new Socket();
    socket.peer = host.connect({ send(data) { queueMicrotask(() => socket.dispatchEvent(new MessageEvent('message', { data }))); }, close() { socket.close(); } }, async () => true);
    return socket as unknown as WebSocket;
  }, { async load() { return entries; }, async save(_origin, next) { entries = next; } }, () => '00000000-0000-4000-8000-000000000001');
  await controller.start();
  async function window(messages: ChatMessage[], before: string | null) {
    const received = new Promise<void>(resolve => {
      const unsubscribe = controller.subscribe(snapshot => {
        const actual = snapshot.view?.messages;
        if (actual?.length === messages.length && actual.every((item, i) => item.id === messages[i].id && item.text === messages[i].text && item.textState === messages[i].textState) && snapshot.view?.before === before) { queueMicrotask(unsubscribe); resolve(); }
      });
    });
    changed({ type: 'update', scope, window: { messages, before } });
    await received;
  }
  async function remove(id: string) {
    const received = new Promise<void>(resolve => {
      const unsubscribe = controller.subscribe(snapshot => {
        if (!snapshot.view?.messages.some(item => item.id === id)) { queueMicrotask(unsubscribe); resolve(); }
      });
    });
    changed({ type: 'update', scope, messages: [{ type: 'remove', id }] });
    await received;
  }
  async function session(next: ChatView) {
    const received = new Promise<void>(resolve => {
      const unsubscribe = controller.subscribe(snapshot => {
        if (snapshot.view?.sessionId === next.sessionId) { queueMicrotask(unsubscribe); resolve(); }
      });
    });
    const nextScope = Symbol('test-next'); changed({ type: 'session', scope, nextScope, view: next }); scope = nextScope;
    await received;
  }
  return { controller, window, remove, session, requests, disconnect() { socket.close(); }, publish(messages: ChatMessage[], before: string | null) { changed({ type: 'update', scope, window: { messages, before } }); }, close() { controller.stop(); host.close(); } };
}

async function confirmedInsertion(insertInside: boolean) {
  const reply: ChatMessage = { id: 'answer', role: 'agent', text: 'first\n', textState: 'streaming', createdAt: 30, operationId: null, turnId: 'turn' };
  const f = await setup(view([...Array.from({ length: 29 }, (_, i) => message(i)), reply], 'older'), { older: { messages: [message(-1)], before: null } });
  try {
    await f.controller.loadOlder();
    const operationId = await f.controller.send('fixture pending');
    const before = visibleRowsFor(f.controller.snapshot());
    const pending = before.find(row => row.operationId === operationId);
    assert.ok(pending?.pendingState);
    const remaining = Array.from({ length: 28 }, (_, i) => message(i + 1));
    const confirmed: ChatMessage = { ...message(30), id: 'confirmed', operationId, text: 'fixture pending' };
    const changedReply: ChatMessage = { ...reply, text: 'first\nsecond\n' };
    const next = insertInside
      ? [...remaining.slice(0, 10), confirmed, ...remaining.slice(10), changedReply]
      : [...remaining, changedReply, confirmed];
    await f.window(next, 'newer');
    const snapshot = f.controller.snapshot();
    const after = visibleRowsFor(snapshot);
    return { before, after, pendingKey: pending._id, snapshot };
  } finally { f.close(); }
}

test('pending confirmation with ordered insertion and advancing window retains a continuous prefix', async () => {
  const { before, after, pendingKey, snapshot } = await confirmedInsertion(true);
  assert.equal(snapshot.detached.length, 0);
  assert.equal(after.filter(row => row.kind === 'gap').length, 0);
  assert.equal(after.filter(row => row._id === pendingKey).length, 1);
  const original = before.filter(row => row._id !== pendingKey).map(row => row._id);
  assert.deepEqual(after.filter(row => original.includes(row._id)).map(row => row._id), original);
});

test('pending confirmation without an internal insertion is a negative control', async () => {
  const { before, after, pendingKey, snapshot } = await confirmedInsertion(false);
  assert.equal(snapshot.detached.length, 0);
  assert.equal(after.filter(row => row.kind === 'gap').length, 0);
  assert.equal(after.filter(row => row._id === pendingKey).length, 1);
  const original = before.filter(row => row._id !== pendingKey).map(row => row._id);
  assert.deepEqual(after.filter(row => original.includes(row._id)).map(row => row._id), original);
});

test('ordered insertion does not move retained rows across prior history', async () => {
  const { before, after, pendingKey } = await confirmedInsertion(true);
  const original = before.filter(row => row._id !== pendingKey).map(row => row._id);
  assert.deepEqual(after.filter(row => original.includes(row._id)).map(row => row._id), original);
});

test('minimum advancing window with an internal insertion has no detached head', async () => {
  const f = await setup(view([message(0), message(1), message(2)], 'older'), { older: { messages: [message(-1)], before: null } });
  try {
    await f.controller.loadOlder();
    await f.window([message(1), message(3), message(2)], 'new');
    assert.deepEqual(f.controller.snapshot().detached, []);
    assert.deepEqual(visibleRowsFor(f.controller.snapshot()).map(row => row._id), ['m-1', 'm0', 'm1', 'm3', 'm2']);
  } finally { f.close(); }
});

test('ordered insertion without a displaced head is a negative control', async () => {
  const f = await setup(view([message(0), message(1), message(2)]));
  try {
    await f.window([message(0), message(3), message(1), message(2)], null);
    assert.deepEqual(f.controller.snapshot().detached, []);
    assert.deepEqual(visibleRowsFor(f.controller.snapshot()).map(row => row._id), ['m0', 'm3', 'm1', 'm2']);
  } finally { f.close(); }
});

test('ordered insertion after an empty window keeps the loaded prefix in order', async () => {
  const f = await setup(view([message(0), message(1), message(2)]));
  try {
    await f.window([], null);
    await f.window([message(1), message(3), message(2)], 'new');
    assert.deepEqual(f.controller.snapshot().detached, []);
    assert.deepEqual(visibleRowsFor(f.controller.snapshot()).map(row => row._id), ['m0', 'm1', 'm3', 'm2']);
  } finally { f.close(); }
});

test('missing an old item or reordering common items does not claim ordered continuity', async () => {
  for (const next of [[message(1), message(3)], [message(1), message(3), message(2), message(4)], [message(2), message(0), message(3)]]) {
    const f = await setup(view([message(0), message(1), message(2), message(3)]));
    try {
      await f.window(next, 'new');
      assert.ok(f.controller.snapshot().detached.some(range => range.messages.some(item => item.id === 'm1' || item.id === 'm0')));
      assert.ok(visibleRowsFor(f.controller.snapshot()).some(row => row.kind === 'gap'));
    } finally { f.close(); }
  }
});

test('advancing two 30-message windows preserves loaded rows and their positions', async () => {
  const f = await setup(view(Array.from({ length: 30 }, (_, i) => message(i))));
  try {
    const original = rowsFor(f.controller.snapshot()).map(row => row._id);
    for (const start of [2, 4]) {
      await f.window(Array.from({ length: 30 }, (_, i) => message(i + start)), `cursor${start}`);
      assert.deepEqual(rowsFor(f.controller.snapshot()).slice(0, 30).map(row => row._id), original);
    }
    assert.equal(f.controller.snapshot().before, null);
    await f.controller.loadOlder(); assert.deepEqual(f.requests, []);
  } finally { f.close(); }
});

test('negative control: appending without removing the window head preserves rows', async () => {
  const f = await setup(view(Array.from({ length: 28 }, (_, i) => message(i))));
  try {
    const original = rowsFor(f.controller.snapshot()).map(row => row._id);
    await f.window(Array.from({ length: 30 }, (_, i) => message(i)), null);
    assert.deepEqual(rowsFor(f.controller.snapshot()).slice(0, 28).map(row => row._id), original);
  } finally { f.close(); }
});

test('minimum overlap: retaining the displaced head requires just two messages and one advancing window', async () => {
  const f = await setup(view([message(0), message(1)]));
  try {
    await f.window([message(1), message(2)], 'cursor');
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), ['m0', 'm1', 'm2']);
  } finally { f.close(); }
});

test('page overlap deduplicates and live same-ID values stay authoritative', async () => {
  const f = await setup(view([message(2), message(3)], 'older'), { older: { messages: [message(0), message(1), message(2)], before: null } });
  try {
    await f.controller.loadOlder();
    await f.window([{ ...message(2), text: 'updated' }, message(3), message(4)], 'newer');
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), ['m0', 'm1', 'm2', 'm3', 'm4']);
    assert.equal(rowsFor(f.controller.snapshot()).find(row => row._id === 'm2')?.text, 'updated');
    await f.window([message(3), message(4), message(5)], 'newer2');
    assert.equal(rowsFor(f.controller.snapshot()).find(row => row._id === 'm2')?.text, 'updated');
    assert.equal(f.controller.snapshot().before, null);
  } finally { f.close(); }
});

test('empty initial window adopts later cursor without losing the earlier boundary', async () => {
  const f = await setup(view([]), { older: { messages: [message(0)], before: null } });
  try {
    await f.window([message(1)], 'older');
    await f.controller.loadOlder();
    assert.deepEqual(f.requests, ['older']);
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), ['m0', 'm1']);
  } finally { f.close(); }
});

test('a transient empty window retains the loaded range and its older cursor through recovery', async () => {
  const f = await setup(view([message(2), message(3)], 'older'), {
    older: { messages: [message(0), message(1)], before: 'oldest' },
    oldest: { messages: [message(-2), message(-1)], before: null },
  });
  try {
    await f.controller.loadOlder();
    await f.window([], null);
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), ['m0', 'm1', 'm2', 'm3']);
    assert.equal(f.controller.snapshot().before, 'oldest');
    await f.window([message(3), message(4)], 'new');
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), ['m0', 'm1', 'm2', 'm3', 'm4']);
    assert.equal(f.controller.snapshot().before, 'oldest');
    await f.controller.loadOlder();
    assert.deepEqual(f.requests, ['older', 'oldest']);
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), ['m-2', 'm-1', 'm0', 'm1', 'm2', 'm3', 'm4']);
  } finally { f.close(); }
});

test('a transient empty window retains a live range without prior pagination', async () => {
  const f = await setup(view([message(0), message(1)], 'older'));
  try {
    await f.window([], null);
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), ['m0', 'm1']);
    assert.equal(f.controller.snapshot().before, 'older');
    await f.window([message(1), message(2)], 'new');
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), ['m0', 'm1', 'm2']);
    assert.equal(f.controller.snapshot().before, 'older');
  } finally { f.close(); }
});

test('older history remains pageable while the live window is empty', async () => {
  const f = await setup(view([message(1), message(2)], 'older'), { older: { messages: [message(0)], before: null } });
  try {
    await f.window([], null);
    await f.controller.loadOlder();
    assert.deepEqual(f.requests, ['older']);
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), ['m0', 'm1', 'm2']);
    await f.window([message(2), message(3)], 'newer');
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), ['m0', 'm1', 'm2', 'm3']);
    assert.equal(f.controller.snapshot().before, null);
  } finally { f.close(); }
});

test('an empty window followed by a disjoint window waits for a history bridge', async () => {
  const f = await setup(view([message(0), message(1)], 'older'), { gap: { messages: [message(1), message(2), message(3)], before: 'unused' } });
  try {
    await f.window([], null);
    await f.window([message(4), message(5)], 'gap');
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), ['m4', 'm5']);
    await f.controller.loadOlder();
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), ['m0', 'm1', 'm2', 'm3', 'm4', 'm5']);
    assert.equal(f.controller.snapshot().before, 'older');
  } finally { f.close(); }
});

test('two disjoint windows reconnect one retained layer at a time', async () => {
  const f = await setup(view([message(0), message(1)], 'older'), {
    second: { messages: [message(5), message(6), message(7)], before: 'unused2' },
    first: { messages: [message(1), message(2), message(3)], before: 'unused1' },
  });
  try {
    await f.window([message(4), message(5)], 'first');
    await f.window([message(8), message(9)], 'second');
    await f.controller.loadOlder();
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), ['m4', 'm5', 'm6', 'm7', 'm8', 'm9']);
    assert.equal(f.controller.snapshot().before, 'first');
    await f.controller.loadOlder();
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), Array.from({ length: 10 }, (_, i) => `m${i}`));
    assert.equal(f.controller.snapshot().before, 'older');
    assert.deepEqual(f.requests, ['second', 'first']);
  } finally { f.close(); }
});

test('one history page can bridge two disjoint retained layers', async () => {
  const f = await setup(view([message(0), message(1)], 'older'), {
    second: { messages: [1, 2, 3, 4, 5, 6, 7].map(message), before: 'unused' },
  });
  try {
    await f.window([message(4), message(5)], 'first');
    await f.window([message(8), message(9)], 'second');
    await f.controller.loadOlder();
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), Array.from({ length: 10 }, (_, i) => `m${i}`));
    assert.equal(f.controller.snapshot().before, 'older');
  } finally { f.close(); }
});

test('a bridge beginning before a retained segment preserves the page cursor', async () => {
  const f = await setup(view([message(4), message(5)], 'segment-older'), {
    gap: { messages: [2, 3, 4, 5, 6, 7].map(message), before: 'page-older' },
    'page-older': { messages: [message(0), message(1)], before: null },
  });
  try {
    await f.window([message(8), message(9)], 'gap');
    await f.controller.loadOlder();
    assert.equal(f.controller.snapshot().before, 'page-older');
    await f.controller.loadOlder();
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), Array.from({ length: 10 }, (_, i) => `m${i}`));
    assert.deepEqual(f.requests, ['gap', 'page-older']);
  } finally { f.close(); }
});

test('a shared tail with ambiguous preceding order does not attach the older prefix', async () => {
  const f = await setup(view([message(0), message(2)]), { gap: { messages: [message(1), message(2), message(3)], before: null } });
  try {
    await f.window([message(4), message(5)], 'gap');
    await f.controller.loadOlder();
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), ['m1', 'm2', 'm3', 'm4', 'm5']);
    assert.equal(f.controller.snapshot().before, null);
  } finally { f.close(); }
});

test('a missing cursor leaves multiple detached ranges unavailable to the timeline', async () => {
  const f = await setup(view([message(0), message(1)]));
  try {
    await f.window([message(4), message(5)], 'first');
    await f.window([message(8), message(9)], null);
    await f.controller.loadOlder();
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), ['m8', 'm9']);
    assert.deepEqual(f.requests, []);
    assert.equal(f.controller.snapshot().before, null);
  } finally { f.close(); }
});

test('snapshots expose immutable separate ranges and notify on detach, bridge and stop', async () => {
  const first: ChatMessage = { ...message(0), files: [{ attachmentId: 'file', name: 'fixture.txt', mediaType: 'text/plain', size: 1, availability: 'available' }] };
  const f = await setup(view([first, message(1)]), {
    second: { messages: [message(5), message(6), message(7)], before: 'unused2' },
    first: { messages: [message(1), message(2), message(3)], before: 'unused1' },
  });
  const notifications: number[] = [];
  const unsubscribe = f.controller.subscribe(snapshot => { notifications.push(snapshot.detached?.length ?? -1); });
  try {
    await f.window([message(4), message(5)], 'first');
    const oldSnapshot = f.controller.snapshot().detached;
    assert.deepEqual(oldSnapshot.map(range => range.messages.map(item => item.id)), [['m0', 'm1']]);
    assert.ok(Object.isFrozen(oldSnapshot)); assert.ok(Object.isFrozen(oldSnapshot[0]));
    assert.ok(Object.isFrozen(oldSnapshot[0].messages)); assert.ok(Object.isFrozen(oldSnapshot[0].messages[0]));
    assert.ok(Object.isFrozen(oldSnapshot[0].messages[0].files)); assert.ok(Object.isFrozen(oldSnapshot[0].messages[0].files![0]));
    assert.equal(Reflect.set(oldSnapshot[0].messages[0].files![0], 'name', 'changed'), false);
    await f.window([message(8), message(9)], 'second');
    const ranges = f.controller.snapshot().detached;
    assert.deepEqual(ranges.map(range => range.messages.map(item => item.id)), [['m0', 'm1'], ['m4', 'm5']]);
    assert.equal(ranges[0].id, oldSnapshot[0].id); assert.notEqual(ranges[0].id, ranges[1].id);
    assert.equal(oldSnapshot.length, 1);
    await f.controller.loadOlder();
    assert.deepEqual(f.controller.snapshot().detached.map(range => range.id), [ranges[0].id]);
    await f.controller.loadOlder(); assert.deepEqual(f.controller.snapshot().detached, []);
    assert.deepEqual(ranges.map(range => range.messages.map(item => item.id)), [['m0', 'm1'], ['m4', 'm5']]);
    assert.ok(notifications.includes(2));
    assert.ok(notifications.some((count, index) => count === 1 && notifications[index - 1] === 2));
    f.controller.stop(); assert.deepEqual(f.controller.snapshot().detached, []);
  } finally { unsubscribe(); f.close(); }
});

test('detached snapshots are cleared and notified on scope change and stop', async () => {
  const f = await setup(view([message(0), message(1)]));
  let lastCount = -1; const unsubscribe = f.controller.subscribe(snapshot => { lastCount = snapshot.detached?.length ?? -1; });
  try {
    await f.window([message(4), message(5)], null); assert.equal(lastCount, 1);
    await f.session({ ...view([message(10)]), sessionId: 'next' }); assert.equal(lastCount, 0);
    await f.window([message(14), message(15)], null); assert.equal(lastCount, 1);
    f.controller.stop(); assert.equal(lastCount, 0);
  } finally { unsubscribe(); f.close(); }
});

test('empty live window keeps the active range and any earlier detached segment', async () => {
  const f = await setup(view([message(0), message(1)]));
  try {
    await f.window([message(4), message(5)], 'gap');
    const id = f.controller.snapshot().detached[0].id;
    await f.window([], null);
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), ['m4', 'm5']);
    assert.deepEqual(f.controller.snapshot().detached.map(range => range.id), [id]);
    assert.equal(f.controller.snapshot().before, 'gap');
    await f.window([message(5), message(6)], 'new');
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), ['m4', 'm5', 'm6']);
    assert.deepEqual(f.controller.snapshot().detached.map(range => range.id), [id]);
  } finally { f.close(); }
});

test('pending confirmation preserves the operation row identity', async () => {
  const operationId = '00000000-0000-4000-8000-000000000001';
  const pending: Pending = { origin: 'fixture://memory', sessionId: 'fixture', operationId, text: 'pending', createdAt: 1, state: 'unknown', deliveryVersion: 2 };
  const f = await setup(view([message(0)]), {}, [pending]);
  try {
    const key = rowsFor(f.controller.snapshot()).find(row => row.operationId === operationId)?._id;
    assert.ok(key);
    await f.window([message(0), { ...message(1), operationId, text: 'pending' }], null);
    const matching = rowsFor(f.controller.snapshot()).filter(row => row.operationId === operationId);
    assert.equal(matching.length, 1); assert.equal(matching[0]._id, key);
  } finally { f.close(); }
});

test('reconnect without overlap pages backward until the old range is proven connected', async () => {
  const f = await setup(view([message(0), message(1)]), {
    gap: { messages: [message(4), message(5)], before: 'bridge' },
    bridge: { messages: [message(1), message(2), message(3)], before: 'older-than-bridge' },
  });
  try {
    f.disconnect(); f.publish([message(6), message(7)], 'gap');
    await new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => { unsubscribe(); reject(Error('reconnect timeout')); }, 5000);
      const unsubscribe = f.controller.subscribe(snapshot => {
        if (snapshot.connection === 'online' && snapshot.view?.messages[0]?.id === 'm6') { clearTimeout(timeout); queueMicrotask(unsubscribe); resolve(); }
      });
    });
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), ['m6', 'm7']);
    await f.controller.loadOlder();
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), ['m4', 'm5', 'm6', 'm7']);
    await f.controller.loadOlder();
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), Array.from({ length: 8 }, (_, i) => `m${i}`));
    assert.equal(f.controller.snapshot().before, null);
    assert.deepEqual(f.requests, ['gap', 'bridge']);
  } finally { f.close(); }
});

test('reconnect with overlapping window retains the old head immediately', async () => {
  const f = await setup(view([message(0), message(1)]));
  try {
    f.disconnect(); f.publish([message(1), message(2)], 'older');
    await new Promise<void>((resolve, reject) => {
      const timeout = setTimeout(() => { unsubscribe(); reject(Error('reconnect timeout')); }, 5000);
      const unsubscribe = f.controller.subscribe(snapshot => {
        if (snapshot.connection === 'online' && snapshot.view?.messages.at(-1)?.id === 'm2') { clearTimeout(timeout); queueMicrotask(unsubscribe); resolve(); }
      });
    });
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), ['m0', 'm1', 'm2']);
    assert.equal(f.controller.snapshot().before, null);
  } finally { f.close(); }
});

test('scope invalidation releases retained history', async () => {
  const f = await setup(view([message(0), message(1)]));
  try {
    await f.window([message(1), message(2)], 'older');
    const active = f.controller.scope();
    f.controller.stop();
    assert.equal(active(), false); assert.equal(f.controller.snapshot().view, null); assert.deepEqual(f.controller.snapshot().history, []);
  } finally { f.close(); }
});

test('session change invalidates retained and detached ranges', async () => {
  const f = await setup(view([message(0), message(1)]), { gap: { messages: [message(1), message(2)], before: null } });
  try {
    await f.window([message(3), message(4)], 'gap');
    const old = f.controller.scope();
    await f.session({ ...view([message(10)]), sessionId: 'next' });
    assert.equal(old(), false);
    await f.session(view([message(3), message(4)], 'gap'));
    await f.controller.loadOlder();
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), ['m1', 'm2', 'm3', 'm4']);
  } finally { f.close(); }
});

test('streaming source keeps its row identity through repeated and final updates', async () => {
  const answer: ChatMessage = { id: 'answer', role: 'agent', text: 'first\n', textState: 'streaming', createdAt: 1, operationId: null, turnId: 'turn' };
  const f = await setup(view([message(0), answer]));
  try {
    const first = rowsFor(f.controller.snapshot()).find(row => row.text === 'first\n');
    assert.ok(first);
    await f.window([message(0), { ...answer, text: 'first\nsecond\n' }], null);
    assert.equal(rowsFor(f.controller.snapshot())[1]._id, first._id);
    await f.window([message(0), { ...answer, text: 'first\nsecond\n', textState: 'complete' }], null);
    assert.equal(rowsFor(f.controller.snapshot())[1]._id, first._id);
    assert.equal(rowsFor(f.controller.snapshot()).filter(row => row._id === first._id).length, 1);
  } finally { f.close(); }
});

test('a gap without a usable cursor is not presented as continuous', async () => {
  const f = await setup(view([message(0), message(1)]));
  try {
    await f.window([message(5), message(6)], null);
    await f.controller.loadOlder();
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), ['m5', 'm6']);
    assert.deepEqual(f.requests, []);
  } finally { f.close(); }
});

test('history exhaustion without overlap does not attach the old range', async () => {
  const f = await setup(view([message(0), message(1)]), { gap: { messages: [message(4)], before: null } });
  try {
    await f.window([message(5), message(6)], 'gap');
    await f.controller.loadOlder();
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), ['m4', 'm5', 'm6']);
    assert.equal(f.controller.snapshot().before, null);
  } finally { f.close(); }
});

test('an interior remove represented in the current view disappears from the projection', async () => {
  const f = await setup(view([message(0), message(1), message(2)]));
  try {
    await f.remove('m1');
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), ['m0', 'm2']);
    assert.deepEqual(f.controller.snapshot().detached.map(range => range.messages.map(item => item.id)), [['m1']]);
    await f.window([message(0), { ...message(1), text: 'returned' }, message(2)], null);
    assert.deepEqual(f.controller.snapshot().detached, []);
    assert.equal(rowsFor(f.controller.snapshot()).find(row => row._id === 'm1')?.text, 'returned');
  } finally { f.close(); }
});

test('empty then partially overlapping view keeps missing records without reordering the active range', async () => {
  const f = await setup(view([message(0), message(1), message(2)]));
  try {
    await f.window([], null);
    await f.window([message(0), message(2)], null);
    assert.deepEqual(rowsFor(f.controller.snapshot()).map(row => row._id), ['m0', 'm2']);
    assert.deepEqual(f.controller.snapshot().detached.map(range => range.messages.map(item => item.id)), [['m1']]);
  } finally { f.close(); }
});

test('a history response from a disconnected port is discarded', async () => {
  let offline!: (error: Error) => void;
  let release!: (page: { messages: ChatMessage[]; before: null }) => void;
  const port: ChatPort = { history: () => new Promise(resolve => { release = resolve; }), async submit() { throw Error('unused'); }, async lookup() { return null; }, close() {} };
  const controller = new ChatController('fixture://memory', async () => ({ close() {} }) as WebSocket, { async load() { return []; }, async save() {} }, () => 'unused', async (_, changed, fail) => { offline = fail; changed(view([message(1)], 'older')); return port; });
  try {
    await controller.start(); const pending = controller.loadOlder();
    offline(Error('disconnected')); release({ messages: [message(0)], before: null }); await pending;
    assert.deepEqual(controller.snapshot().history, []); assert.equal(controller.snapshot().before, 'older');
  } finally { controller.stop(); }
});

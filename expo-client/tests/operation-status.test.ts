import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ChatController, type ChatPort, type Pending, type PendingStore } from '../src/cfl/chat';
import { outcome } from '../src/cfl/send-outcome';
import type { ChatMessage, ChatView, Receipt } from '../vendor/contracts/src/index';

const id = '00000000-0000-4000-8000-000000000001';
const identity = { origin: 'test-origin', sessionId: 'A', operationId: id };
const message: ChatMessage = { id: 'm', role: 'user', text: 'hello', createdAt: 1, operationId: id, turnId: null };
const view = (sessionId = 'A', messages: ChatMessage[] = []): ChatView => ({ version: 2, sessionId, name: 'fixture', activeTurnId: null, contextUsage: { tokens: null, capacity: null }, compaction: null, messages, before: null, capabilities: { text: true, steer: true, stop: true, images: false } });

function harness() {
  let entries: Pending[] = [], changed = (_: ChatView) => {}, receipt: Receipt | null = null, sent = 0;
  const store: PendingStore = { async load() { return entries; }, async save(_, next) { entries = next; } };
  const port: ChatPort = { async history() { return { messages: [message], before: null }; }, async submit() { sent++; throw Error('response lost'); }, async lookup() { return receipt; }, close() {} };
  const c = new ChatController(identity.origin, async () => ({ close() {} }) as WebSocket, store, () => id, async (_, fn) => { changed = fn; fn(view()); return port; });
  return { c, setView(v: ChatView) { changed(v); }, setReceipt(state: 'submitted' | 'failed') { receipt = { operationId: id, attempt: 1, state, messageId: state === 'submitted' ? 'm' : null, turnId: null, error: state === 'failed' ? 'rejected' : null }; }, sent: () => sent };
}

for (const state of ['submitted', 'failed'] as const) test(`unknown becomes ${state} only after receipt, without replay`, async () => {
  const h = harness(); await h.c.start(); const result = await outcome(h.c, h.c.send('hello'));
  assert.deepEqual(result, { ...identity, state: 'unknown' });
  h.setReceipt(state); await h.c.reconcile(); assert.equal(await h.c.operationStatus(identity), state); assert.equal(h.sent(), 1); h.c.stop();
});

test('matching view or loaded history is observed; missing records are unknown', async () => {
  const h = harness(); await h.c.start();
  assert.equal((await outcome(h.c, Promise.resolve(id))).state, 'unknown');
  assert.equal(await h.c.operationStatus(identity), 'unknown');
  h.setView(view('A', [message])); assert.equal(await h.c.operationStatus(identity), 'observed');
  h.setView(view('B')); h.setView({ ...view(), before: 'older' }); await h.c.loadOlder(); assert.equal(await h.c.operationStatus(identity), 'observed');
  assert.equal(await h.c.operationStatus({ ...identity, origin: 'other-origin' }), 'unknown'); h.c.stop();
});

test('unknown to observed is proven by the message even after journal entry is removed', async () => {
  const h = harness(); await h.c.start(); await h.c.send('hello');
  assert.equal(await h.c.operationStatus(identity), 'unknown');
  h.setView(view('A', [message])); await h.c.reconcile();
  assert.equal(h.c.snapshot().pending.length, 0); assert.equal(await h.c.operationStatus(identity), 'observed');
  h.setView(view()); assert.equal(await h.c.operationStatus(identity), 'unknown'); assert.equal(h.sent(), 1); h.c.stop();
});

test('A to B to A and stop/restart never interpret absence as success or resend', async () => {
  const h = harness(); await h.c.start(); await h.c.send('hello'); h.setReceipt('submitted'); await h.c.reconcile();
  assert.equal(await h.c.operationStatus(identity), 'submitted'); h.setView(view('B'));
  assert.equal(h.c.snapshot().pending.length, 0); assert.equal(await h.c.operationStatus(identity), 'unknown');
  h.setView(view('A')); assert.equal(await h.c.operationStatus(identity), 'submitted'); h.c.stop();
  assert.equal(await h.c.operationStatus(identity), 'unknown'); await h.c.start();
  assert.equal(await h.c.operationStatus(identity), 'submitted'); assert.equal(h.sent(), 1); h.c.stop();
});

test('in-flight outcome returns unknown on session change or stop, and queued send cannot cross sessions', async () => {
  const h = harness(); await h.c.start();
  let finish!: (id: string) => void; const wait = () => new Promise<string>(r => { finish = r; });
  const a = outcome(h.c, wait()); h.setView(view('B')); finish(id); assert.equal((await a).state, 'unknown');
  h.setView(view('A')); const b = outcome(h.c, wait()); h.c.stop(); finish(id); assert.equal((await b).state, 'unknown');
  await h.c.start(); let finishPrepare!: () => void, started!: () => void;
  const preparing = new Promise<void>(r => { started = r; });
  const first = h.c.sendPrepared('first', async () => { await new Promise<void>(r => { finishPrepare = r; started(); }); return {}; });
  await preparing; const queued = h.c.send('queued'); h.setView(view('B')); finishPrepare();
  await assert.rejects(first, /session_changed/); await assert.rejects(queued, /session_changed/); assert.equal(h.sent(), 0); h.c.stop();
});

test('late journal reads and storage errors cannot unlock a stale operation', async () => {
  let changed!: (v: ChatView) => void, finish!: (entries: Pending[]) => void, delayed = false, broken = false;
  const entry: Pending = { ...identity, text: 'hello', createdAt: 1, state: 'submitted', attempt: 1, deliveryVersion: 2 };
  const store: PendingStore = { async load() { if (broken) throw Error('storage failure'); return delayed ? new Promise<Pending[]>(r => { finish = r; }) : [entry]; }, async save() {} };
  const port: ChatPort = { async history() { return { messages: [], before: null }; }, async submit() { throw Error('unused'); }, async lookup() { return null; }, close() {} };
  const c = new ChatController(identity.origin, async () => ({ close() {} }) as WebSocket, store, () => id, async (_, fn) => { changed = fn; fn(view()); return port; });
  await c.start(); delayed = true; const status = c.operationStatus(identity); changed(view('B')); finish([entry]);
  assert.equal(await status, 'unknown'); changed(view('A')); broken = true;
  assert.equal(await c.operationStatus(identity), 'unknown'); c.stop();
});

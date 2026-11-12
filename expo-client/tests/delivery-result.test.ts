import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ChatController, type ChatPort, type Pending, type PendingStore } from '../src/cfl/chat';
import type { ChatView, Receipt } from '../vendor/contracts/src/index';

const id = '00000000-0000-4000-8000-000000000001';
const view = (sessionId = 'A'): ChatView => ({ version: 2, sessionId, name: 'fixture', activeTurnId: null, contextUsage: { tokens: null, capacity: null }, compaction: null, messages: [], before: null, capabilities: { text: true, steer: true, stop: true, images: false } });
const receipt = (attempt: number, state: 'submitted' | 'failed'): Receipt => ({ operationId: id, attempt, state, messageId: state === 'submitted' ? 'm' : null, turnId: null, error: state === 'failed' ? 'rejected' : null });
const tick = () => new Promise<void>(resolve => setImmediate(resolve));

test('deliveryResult settles a pending submit; a late older RPC cannot overwrite it', async () => {
  let entries: Pending[] = [], delivery!: (receipt: Receipt) => void, finish!: (receipt: Receipt) => void, started!: () => void, sent = 0;
  const dispatch = new Promise<void>(resolve => { started = resolve; });
  const store: PendingStore = { async load() { return entries; }, async save(_, next) { entries = next; } };
  const port: ChatPort = { async history() { return { messages: [], before: null }; }, submit() { sent++; started(); return new Promise(resolve => { finish = resolve; }); }, async lookup() { return null; }, close() {} };
  const c = new ChatController('origin', async () => ({ close() {} }) as WebSocket, store, () => id, async (_, changed, _offline, notify) => { delivery = notify; changed(view()); return port; });
  await c.start(); const send = c.send('hello'); await dispatch;
  assert.equal(entries[0].state, 'unknown'); delivery(receipt(2, 'submitted')); await tick();
  assert.equal(entries[0].state, 'submitted'); assert.equal(entries[0].attempt, 2);
  finish(receipt(1, 'failed')); await send;
  assert.equal(entries[0].state, 'submitted'); assert.equal(sent, 1); c.stop();
});

test('delivery results are attempt ordered and a stale connection cannot change a restarted session', async () => {
  let entries: Pending[] = [], notify!: (receipt: Receipt) => void, changed!: (view: ChatView) => void, sent = 0;
  const store: PendingStore = { async load() { return entries; }, async save(_, next) { entries = next; } };
  const port: ChatPort = { async history() { return { messages: [], before: null }; }, async submit() { sent++; throw Error('lost'); }, async lookup() { return null; }, close() {} };
  const c = new ChatController('origin', async () => ({ close() {} }) as WebSocket, store, () => id, async (_, update, _offline, delivery) => { changed = update; notify = delivery; update(view()); return port; });
  await c.start(); await c.send('hello'); notify(receipt(2, 'failed')); await tick(); assert.equal(entries[0].state, 'failed');
  notify(receipt(1, 'submitted')); await tick(); assert.equal(entries[0].state, 'failed');
  notify(receipt(2, 'submitted')); await tick(); assert.equal(entries[0].state, 'failed');
  notify(receipt(3, 'submitted')); await tick(); assert.equal(entries[0].state, 'submitted'); assert.equal(entries[0].attempt, 3);
  notify(receipt(4, 'failed')); await tick(); assert.equal(entries[0].state, 'submitted');
  changed(view('B')); notify(receipt(4, 'failed')); await tick(); assert.equal(entries[0].state, 'submitted');
  changed(view('A')); const stale = notify; c.stop(); await c.start(); stale(receipt(4, 'failed')); await tick(); assert.equal(entries[0].state, 'submitted'); assert.equal(sent, 1); c.stop();
});

test('legacy journal terminal claims remain unknown until a new receipt or observed message', async () => {
  for (const oldState of ['submitted', 'failed'] as const) {
    const entries: Pending[] = [{ origin: 'origin', sessionId: 'A', operationId: id, text: 'old', createdAt: 0, state: oldState }]; let sent = 0;
    const store: PendingStore = { async load() { return entries; }, async save() {} };
    const port: ChatPort = { async history() { return { messages: [], before: null }; }, async submit() { sent++; throw Error('unexpected'); }, async lookup() { return null; }, close() {} };
    const c = new ChatController('origin', async () => ({ close() {} }) as WebSocket, store, () => id, async (_, changed) => { changed(view()); return port; });
    await c.start(); await c.reconcile(); assert.equal(await c.operationStatus({ origin: 'origin', sessionId: 'A', operationId: id }), 'unknown'); assert.equal(sent, 0); c.stop();
  }
});

test('queued receipt from before A to B to A is discarded, not applied to the returned session', async () => {
  let entries: Pending[] = [{ origin: 'origin', sessionId: 'A', operationId: id, text: 'old', createdAt: 0, state: 'unknown', deliveryVersion: 2 }];
  let changed!: (view: ChatView) => void, notify!: (receipt: Receipt) => void, release!: () => void, began!: () => void;
  const started = new Promise<void>(resolve => { began = resolve; });
  const store: PendingStore = { async load() { return entries; }, async save(_, next) { entries = next; } };
  const port: ChatPort = { async history() { return { messages: [], before: null }; }, async submit() { throw Error('unexpected'); }, async lookup() { return null; }, close() {} };
  const c = new ChatController('origin', async () => ({ close() {} }) as WebSocket, store, () => '00000000-0000-4000-8000-000000000002', async (_, update, _offline, delivery) => { changed = update; notify = delivery; update(view()); return port; });
  await c.start(); await c.reconcile();
  const blocked = c.sendPrepared('new', async () => { began(); await new Promise<void>(resolve => { release = resolve; }); return {}; });
  await started; notify(receipt(1, 'submitted')); changed(view('B')); changed(view('A')); release();
  await assert.rejects(blocked, /session_changed/); await tick(); assert.equal(entries[0].state, 'unknown'); c.stop();
});

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createChatHost, type ChatBackend, type ChatChange } from '../vendor/contracts/src/server';
import { openChat } from '../vendor/contracts/src/client';
import type { ChatView } from '../vendor/contracts/src/index';

const initial: ChatView = { version: 2, sessionId: 'synthetic', name: 'test', activeTurnId: null, contextUsage: { tokens: null, capacity: null }, compaction: null, messages: [], before: 'cursor', capabilities: { text: true, steer: true, stop: true, images: false } };
test('upstream Chord wire: subscribe, history, send, receipt lookup and streamed state', async () => {
  const scope = Symbol(); let changed!: (event: ChatChange) => void; let sent = 0;
  const backend = {
    async read() { return initial; }, subscribe(fn: typeof changed) { changed = fn; return { scope, close() {} }; },
    async history() { return { messages: [{ id: 'old', role: 'user', text: 'earlier', createdAt: 1, operationId: null, turnId: null }], before: null }; },
    async submit(input: { operationId: string }) { sent++; return { operationId: input.operationId, attempt: 1, state: 'submitted', messageId: 'm', turnId: null, error: null }; },
    async lookup(id: string) { return { operationId: id, attempt: 1, state: 'submitted', messageId: 'm', turnId: null, error: null }; },
  } as unknown as ChatBackend;
  const host = await createChatHost(backend, e => { throw e; });
  class Socket extends EventTarget {
    readyState = 1;
    peer!: ReturnType<typeof host.connect>;
    send(data: string) { void this.peer.receive(data); }
    close() { if (this.readyState === 3) return; this.readyState = 3; this.dispatchEvent(new Event('close')); }
  }
  const socket = new Socket();
  socket.peer = host.connect({ send(data) { queueMicrotask(() => socket.dispatchEvent(new MessageEvent('message', { data }))); }, close() { socket.close(); } }, async () => true);
  let view: ChatView | undefined;
  let deliver!: (receipt: import('../vendor/contracts/src/index').Receipt) => void;
  const delivered = new Promise<import('../vendor/contracts/src/index').Receipt>(resolve => { deliver = resolve; });
  const client = await openChat(socket as unknown as WebSocket, next => { view = next; }, () => {}, deliver);
  assert.equal(view?.sessionId, 'synthetic'); assert.equal((await client.history('cursor')).messages[0]?.id, 'old');
  const op = '00000000-0000-4000-8000-000000000001'; assert.equal((await client.submit({ operationId: op, text: 'hello' })).state, 'submitted'); assert.equal((await client.lookup(op))?.messageId, 'm'); assert.equal(sent, 1);
  changed({ type: 'deliveryResult', scope, receipt: { operationId: op, attempt: 2, state: 'failed', messageId: null, turnId: null, error: 'rejected' } });
  assert.equal((await delivered).attempt, 2);
  changed({ type: 'update', scope, state: { streamingReply: { id: 'reply', turnId: null, createdAt: 2, text: 'stream' } } });
  await new Promise(resolve => setTimeout(resolve, 20)); assert.equal(view?.streamingReply?.text, 'stream');
  client.close(); host.close();
});

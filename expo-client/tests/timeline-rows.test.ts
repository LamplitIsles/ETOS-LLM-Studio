import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { ChatMessage, ChatView } from '../vendor/contracts/src/index';
import { ChatController, type ChatPort, type ChatSnapshot, type Pending, type PendingStore } from '../src/cfl/chat';
import { rowsFor, sendPlacement } from '../src/ui/timelineRows';
import { createFixture } from './fixtures/fixture';

const fixture = createFixture();
const baseView = fixture.read();
const message = (id: string, text: string, ends: number[]): ChatMessage => ({ id, role: 'agent', text, ends, createdAt: 2, operationId: null, turnId: null });
const snapshot = (patch: Partial<ChatView>, history: ChatMessage[] = []): ChatSnapshot => ({ connection: 'online', failure: null, view: { ...baseView, messages: [], ...patch }, history, before: null, pending: [] });

test('renders only host-published UTF-16 ranges and keeps preview/final identities', () => {
  const text = '你好😀\n第二行\n尚未完成';
  const first = '你好😀\n'.length;
  const second = '你好😀\n第二行\n'.length;
  const preview = { id: 'reply', turnId: null, createdAt: 2, text, ends: [first, second] };
  const streaming = rowsFor(snapshot({ streamingReply: preview }));
  assert.deepEqual(streaming.map(row => row.text), ['你好😀\n', '第二行\n']);
  const completed = rowsFor(snapshot({ messages: [message('reply', text, [first, second, text.length])] }));
  assert.deepEqual(completed.map(row => row.text), ['你好😀\n', '第二行\n', '尚未完成']);
  assert.deepEqual(completed.slice(0, 2).map(row => row._id), streaming.map(row => row._id));
  assert.deepEqual(rowsFor(snapshot({ streamingReply: { ...preview, ends: [] } })), []);
  const differentSession = rowsFor(snapshot({ sessionId: 'other-session', streamingReply: preview }));
  assert.notEqual(differentSession[0]._id, streaming[0]._id);
});

test('history, completed view, non-replies and media are not duplicated', () => {
  const answer = message('answer', '一\n二', [2, 3]);
  const external: ChatMessage = { id: 'outside', role: 'user', text: '原样\n显示', createdAt: 1, operationId: null, turnId: null };
  const withFile: ChatMessage = { ...answer, id: 'with-file', files: [{ attachmentId: 'file', name: 'a.txt', mediaType: 'text/plain', size: 1, availability: 'available' }] };
  const result = rowsFor(snapshot({ messages: [answer, withFile], streamingReply: { id: 'answer', text: answer.text, ends: answer.ends, createdAt: 2, turnId: null } }, [external, answer]));
  assert.deepEqual(result.map(row => row.text), ['原样\n显示', '一\n', '二', '一\n', '二']);
  assert.equal(result.filter(row => row.original?.files?.length).length, 1);
  assert.equal(rowsFor(snapshot({ messages: [{ ...withFile, ends: [] }] }))[0]?.original?.files?.length, 1);
});

test('orders a distinct live preview by timestamp and hides it when disconnected', () => {
  const preview = { id: 'preview', turnId: null, createdAt: 2, text: '一句\n', ends: [3] };
  const later: ChatMessage = { id: 'later', role: 'user', text: '之后', createdAt: 3, operationId: null, turnId: null };
  const state = snapshot({ messages: [later], streamingReply: preview });
  assert.deepEqual(rowsFor(state).map(row => row.text), ['一句\n', '之后']);
  assert.deepEqual(rowsFor({ ...state, connection: 'offline' }).map(row => row.text), ['之后']);
});

test('keeps a pending user message before its live reply', () => {
  const state: ChatSnapshot = {
    ...snapshot({ streamingReply: { id: 'reply', turnId: 'turn', createdAt: 2, text: '回答', ends: [2] } }),
    pending: [{ origin: 'fixture', sessionId: baseView.sessionId, operationId: 'operation', text: '提问', state: 'unknown', createdAt: 1 }],
  };
  assert.deepEqual(rowsFor(state).map(row => row.text), ['提问', '回答']);
});

test('keeps an optimistic user row identity when the server publishes it', () => {
  const pending = { origin: 'fixture', sessionId: baseView.sessionId, operationId: 'operation', text: '提问', state: 'unknown' as const, createdAt: 1 };
  const before: ChatSnapshot = { ...snapshot({}), pending: [pending] };
  const confirmed: ChatMessage = { id: 'server-id', operationId: pending.operationId, role: 'user', text: pending.text, createdAt: 1, turnId: 'turn' };
  const after: ChatSnapshot = { ...snapshot({ messages: [confirmed] }), pending: [pending] };
  assert.equal(rowsFor(before)[0]._id, rowsFor(after)[0]._id);
  assert.equal(rowsFor(after).length, 1);
  assert.equal(rowsFor(after)[0]._id, rowsFor({ ...after, pending: [] })[0]._id);
  const other = { ...after, view: { ...after.view!, sessionId: 'other-session' }, pending: [] };
  assert.notEqual(rowsFor(after)[0]._id, rowsFor(other)[0]._id);
});

test('keeps consecutive sends at their captured position while later replies arrive', () => {
  const existing: ChatMessage = { id: 'existing', role: 'user', text: '已有', createdAt: 100, operationId: null, turnId: null };
  const later = message('later', '后续回复', [4]);
  const state: ChatSnapshot = {
    ...snapshot({ messages: [existing, later] }),
    pending: [
      { origin: 'fixture', sessionId: baseView.sessionId, operationId: 'one', text: '第一条', state: 'unknown', createdAt: 1, anchor: { after: 'existing' } },
      { origin: 'fixture', sessionId: baseView.sessionId, operationId: 'two', text: '第二条', state: 'unknown', createdAt: 2, anchor: { after: 'existing', predecessor: 'one' } },
    ],
  };
  assert.deepEqual(rowsFor(state).map(row => row.text), ['已有', '第一条', '第二条', '后续回复']);
});

test('keeps older history ahead of a send made before any message was visible', () => {
  const older: ChatMessage = { id: 'older', role: 'user', text: '更早', createdAt: 1, operationId: null, turnId: null };
  const newer = message('newer', '新回复', [3]);
  const state: ChatSnapshot = { ...snapshot({ messages: [newer] }, [older]), pending: [{ origin: 'fixture', sessionId: baseView.sessionId, operationId: 'one', text: '提问', state: 'unknown', createdAt: 2, anchor: { after: null } }] };
  assert.deepEqual(rowsFor(state).map(row => row.text), ['更早', '提问', '新回复']);
});

test('keeps newly loaded history before an empty-anchor send even if live preview time is older', () => {
  const older: ChatMessage = { id: 'older', role: 'user', text: '更早', createdAt: 20, operationId: null, turnId: null };
  const state: ChatSnapshot = { ...snapshot({ streamingReply: { id: 'reply', turnId: 'turn', text: '回答', ends: [2], createdAt: 1 } }, [older]), pending: [{ origin: 'fixture', sessionId: baseView.sessionId, operationId: 'one', text: '提问', state: 'unknown', createdAt: 10, anchor: { after: null } }] };
  const texts = rowsFor(state).map(row => row.text);
  assert.ok(texts.indexOf('更早') < texts.indexOf('提问'));
});

test('captures the displayed tail and predecessor from the exact send snapshot', () => {
  const preview = { id: 'live', turnId: 'turn', createdAt: 2, text: '回复', ends: [2] };
  const before = snapshot({ streamingReply: preview });
  const first = sendPlacement(before);
  assert.equal(first.snapshot, before);
  assert.equal(first.after, rowsFor(before)[0]._id);
  const pending: ChatSnapshot = { ...before, pending: [{ origin: 'fixture', sessionId: baseView.sessionId, operationId: 'one', text: '追问', state: 'unknown', createdAt: 3, anchor: { after: first.after } }] };
  const second = sendPlacement(pending);
  assert.equal(second.after, first.after);
  assert.equal(second.predecessor, 'one');
});

test('a message sent during a live reply stays after the part already visible', () => {
  const preview = { id: 'live', turnId: 'turn', createdAt: 2, text: '先前后续', ends: [2] };
  const before = snapshot({ streamingReply: preview });
  const placement = sendPlacement(before);
  const state: ChatSnapshot = { ...snapshot({ streamingReply: { ...preview, ends: [2, 4] } }), pending: [{ origin: 'fixture', sessionId: baseView.sessionId, operationId: 'steer', text: '追问', state: 'unknown', createdAt: 3, anchor: { after: placement.after } }] };
  assert.deepEqual(rowsFor(state).map(row => row.text), ['先前', '追问', '后续']);
});

test('server-provided order takes precedence after the message is published', () => {
  const user: ChatMessage = { id: 'server-user', role: 'user', text: '提问', createdAt: 10, operationId: 'op', turnId: 'turn' };
  const reply = { ...message('server-reply', '回答', [2]), createdAt: 1 };
  const state: ChatSnapshot = { ...snapshot({ messages: [user, reply] }), pending: [{ origin: 'fixture', sessionId: baseView.sessionId, operationId: 'op', text: '提问', createdAt: 10, state: 'submitted', anchor: { after: null } }] };
  assert.deepEqual(rowsFor(state).map(row => row.text), ['提问', '回答']);
});

test('a real admitted send stays ahead of its streamed reply and keeps its key on confirmation', async () => {
  const operationId = '00000000-0000-4000-8000-000000000001';
  const initial = { ...baseView, messages: [], before: null };
  let update = (_view: ChatView) => {};
  let finish!: (value: { operationId: string; attempt: number; state: 'submitted'; messageId: string; turnId: null; error: null }) => void;
  let saved: Pending[] = [];
  const store: PendingStore = { async load() { return saved; }, async save(_, entries) { saved = entries; } };
  const port: ChatPort = {
    async history() { return { messages: [], before: null }; },
    async submit() { return new Promise(resolve => { finish = resolve; }); },
    async lookup() { return null; }, close() {},
  };
  const controller = new ChatController('fixture', async () => ({ close() {} }) as WebSocket, store, () => operationId, async (_, changed) => { update = changed; changed(initial); return port; });
  await controller.start();
  try {
    const admission = await controller.beginPrepared('提问', async () => ({}), sendPlacement(controller.snapshot()));
    const before = rowsFor(controller.snapshot())[0]._id;
    const preview = { id: 'reply', turnId: 'turn', createdAt: 2, text: '回答', ends: [2] };
    update({ ...initial, streamingReply: preview });
    assert.deepEqual(rowsFor(controller.snapshot()).map(row => row.text), ['提问', '回答']);
    const confirmed: ChatMessage = { id: 'server', role: 'user', text: '提问', operationId, turnId: 'turn', createdAt: 1 };
    update({ ...initial, messages: [confirmed], streamingReply: preview });
    const after = rowsFor(controller.snapshot());
    assert.deepEqual(after.map(row => row.text), ['提问', '回答']);
    assert.equal(after[0]._id, before);
    finish({ operationId, attempt: 1, state: 'submitted', messageId: confirmed.id, turnId: null, error: null });
    await admission.completion;
  } finally { controller.stop(); }
});

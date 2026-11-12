import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { ChatMessage, ChatView } from '../vendor/contracts/src/index';
import type { ChatSnapshot } from '../src/cfl/chat';
import { rowsFor } from '../src/ui/timelineRows';
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

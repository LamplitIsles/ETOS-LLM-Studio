import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { ChatControllerSnapshot, Pending } from '../src/cfl/chat';
import type { ChatMessage } from '../vendor/contracts/src/index';
import { createFixture } from './fixtures/fixture';
import { visibleRowsFor, rowsFor, sendPlacement } from '../src/ui/timelineRows';
import { chatTimeHeadings } from '../src/ui/chatTime';

const message = (id: string, text = id, operationId: string | null = null): ChatMessage => ({ id, text, role: 'user', createdAt: 1, operationId, turnId: null });
const fixture = createFixture();
const state = (detached: ChatControllerSnapshot['detached'], messages: ChatMessage[] = [message('live')], pending: Pending[] = []): ChatControllerSnapshot => ({
  connection: 'online', failure: null, view: { ...fixture.read(), messages, streamingReply: undefined }, history: [], before: null, pending, detached,
});

test('shows retained ranges with a gap and leaves the live tail and send placement unchanged', () => {
  const s = state([{ id: 1, messages: [message('old-a'), message('old-b')] }, { id: 2, messages: [message('other')] }]);
  const visible = visibleRowsFor(s);
  assert.deepEqual(visible.map(row => row.kind === 'gap' ? 'gap' : row.text), ['old-a', 'old-b', 'gap', 'other', 'gap', 'live']);
  assert.equal(new Set(visible.map(row => row._id)).size, visible.length);
  assert.equal(sendPlacement(s).after, rowsFor(s).at(-1)?._id);
});

test('prefers active data and does not repeat IDs or empty gap markers', () => {
  const pending: Pending = { origin: 'fixture', sessionId: fixture.read().sessionId, operationId: 'op', text: 'pending', state: 'unknown', createdAt: 1 };
  const s = state([{ id: 1, messages: [message('same', 'stale'), message('old-op', 'duplicate', 'op')] }, { id: 2, messages: [message('same', 'stale-again'), message('unique')] }], [message('same', 'current')], [pending]);
  const visible = visibleRowsFor(s);
  assert.deepEqual(visible.map(row => row.kind === 'gap' ? 'gap' : row.text), ['unique', 'gap', 'current', 'pending']);
});

test('renders no gap when no detached records remain', () => {
  const s = state([]);
  assert.deepEqual(visibleRowsFor(s), rowsFor(s));
});

test('a live streaming reply takes precedence over the same retained message', () => {
  const source: ChatMessage = { ...message('reply', 'old'), role: 'agent', ends: [3] };
  const base = state([{ id: 1, messages: [source] }], []);
  const s: ChatControllerSnapshot = { ...base, view: { ...base.view!, streamingReply: { id: 'reply', text: 'new', ends: [3], createdAt: 1, turnId: null } } };
  const visible = visibleRowsFor(s);
  assert.deepEqual(visible.map(row => row.text), ['new']);
  assert.equal(new Set(visible.map(row => row._id)).size, visible.length);
});

test('a gap resets time grouping without displaying a timestamp on the gap', () => {
  const s = state([{ id: 1, messages: [message('old')] }]);
  const rows = visibleRowsFor(s);
  const headings = chatTimeHeadings(rows, 1);
  assert.ok(headings[rows[0]._id]);
  assert.equal(headings[rows[1]._id], undefined);
  assert.ok(headings[rows[2]._id]);
});

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { chatTimeHeadings, nextChatDayBoundary } from '../src/ui/chatTime';
import type { TimelineRow } from '../src/ui/timelineRows';

const local = (day: number, hour: number, minute: number) => new Date(2026, 10, day, hour, minute).getTime();
const row = (id: string, time: number): TimelineRow => ({ _id: id, text: id, createdAt: time, user: { _id: 'me' } });

test('marks the first message and gaps of at least 15 minutes between adjacent messages', () => {
  const rows = [row('a', local(12, 10, 0)), row('b', local(12, 10, 14)), row('c', local(12, 10, 29)), row('d', local(12, 10, 30))];
  assert.deepEqual({ ...chatTimeHeadings(rows, local(12, 12, 0)) }, { a: '10:00', c: '10:29' });
  assert.deepEqual({ ...chatTimeHeadings([row('older', local(12, 9, 59)), ...rows], local(12, 12, 0)) }, { older: '09:59', c: '10:29' });
});

test('uses Lamplit chat-day boundary and local dates', () => {
  const now = local(12, 4, 0);
  const headings = chatTimeHeadings([row('previous', local(12, 3, 30)), row('today', local(12, 4, 0))], now);
  assert.equal(headings.previous, '昨天 03:30');
  assert.equal(headings.today, '04:00');
  assert.equal(chatTimeHeadings([row('same-day', local(12, 3, 30))], local(12, 3, 59))['same-day'], '03:30');
  assert.equal(nextChatDayBoundary(local(12, 3, 59)), local(12, 4, 0));
  assert.equal(nextChatDayBoundary(now), local(13, 4, 0));
});

test('does not group across an unknown timestamp or let notices change the previous message time', () => {
  const notice = { ...row('notice', local(12, 10, 10)), original: { id: 'notice', role: 'notice', text: 'notice', createdAt: local(12, 10, 10), operationId: null, turnId: null } } as TimelineRow;
  const rows = [row('a', local(12, 10, 0)), notice, row('b', local(12, 10, 15)), row('invalid', NaN), row('c', local(12, 10, 16))];
  assert.deepEqual({ ...chatTimeHeadings(rows, local(12, 12, 0)) }, { a: '10:00', b: '10:15', c: '10:16' });
});

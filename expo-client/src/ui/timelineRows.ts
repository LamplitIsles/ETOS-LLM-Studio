import type { ChatMessage, FileRef, ImageRef } from '../../vendor/contracts/src/index';
import { isReplySource } from '../../vendor/contracts/src/reply-ranges';
import type { ChatControllerSnapshot, ChatSnapshot, SendPlacement } from '../cfl/chat';

export type TimelineRow = { _id: string; text: string; createdAt: number; user: { _id: string }; kind?: 'gap'; operationId?: string; original?: ChatMessage; pendingState?: 'unknown' | 'submitted' | 'failed'; pendingImages?: ImageRef[]; pendingFiles?: FileRef[] };

/** Show only the source ranges published by the host, using the same keys for preview and history. */
export function rowsFor(snapshot: ChatSnapshot): TimelineRow[] {
  const all = [...snapshot.history, ...(snapshot.view?.messages ?? [])];
  const ids = new Set<string>();
  const operationIds = new Set(all.map(message => message.operationId).filter(Boolean));
  const rows: TimelineRow[] = [];
  const sessionId = snapshot.view?.sessionId ?? '';
  const userOperationKey = (operationId: string) => JSON.stringify(['user', sessionId, operationId]);
  const replyRows = (source: { id: string; text: string; ends?: number[]; createdAt: number }, original?: ChatMessage): TimelineRow[] => {
    const projected: TimelineRow[] = [];
    let start = 0;
    for (const [ordinal, end] of (source.ends ?? []).entries()) {
      projected.push({ _id: JSON.stringify(['reply', sessionId, source.id, ordinal]), text: source.text.slice(start, end), createdAt: source.createdAt,
        user: { _id: 'partner' }, ...(ordinal === 0 && original ? { original } : {}) });
      start = end;
    }
    // An answer can contain attachments even before a text range is published.
    if (!(source.ends?.length) && original && (original.images?.length || original.files?.length)) {
      projected.push({ _id: JSON.stringify(['media', sessionId, source.id]), text: '', createdAt: source.createdAt, user: { _id: 'partner' }, original });
    }
    return projected;
  };
  const appendMessage = (item: ChatMessage) => {
    if (ids.has(item.id)) return;
    ids.add(item.id);
    if (isReplySource(item)) rows.push(...replyRows(item, item));
    else rows.push({ _id: item.role === 'user' && item.operationId ? userOperationKey(item.operationId) : item.id, text: item.text, createdAt: item.createdAt, user: { _id: item.role === 'user' ? 'me' : 'partner' }, ...(item.role === 'user' && item.operationId ? { operationId: item.operationId } : {}), original: item });
  };
  snapshot.history.forEach(appendMessage);
  const historyKeys = new Set(rows.map(row => row._id));
  (snapshot.view?.messages ?? []).forEach(appendMessage);
  const preview = snapshot.connection === 'online' ? snapshot.view?.streamingReply : undefined;
  let previewKey: string | undefined;
  if (preview && !ids.has(preview.id)) {
    const index = rows.findIndex(row => row.createdAt > preview.createdAt);
    const projected = replyRows(preview);
    previewKey = projected[0]?._id;
    rows.splice(index < 0 ? rows.length : index, 0, ...projected);
  }
  const tails = new Map<string | null, string>();
  for (const item of snapshot.pending) {
    if (operationIds.has(item.operationId)) continue;
    const row: TimelineRow = { _id: userOperationKey(item.operationId), operationId: item.operationId, text: item.text, createdAt: item.createdAt, user: { _id: 'me' }, pendingState: item.state, pendingImages: item.images, pendingFiles: item.files };
    const anchor = item.anchor;
    const predecessor = anchor?.predecessor ? rows.findIndex(value => value._id === userOperationKey(anchor.predecessor!)) : -1;
    const tail = anchor && tails.has(anchor.after) ? rows.findIndex(value => value._id === tails.get(anchor.after)) : -1;
    const after = anchor?.after ? rows.findIndex(value => value._id === anchor.after) : -1;
    const index = Math.max(predecessor, tail, after);
    // Old journals lack a captured position. Keep them before the live preview,
    // without reordering any server-published messages.
    const previewIndex = previewKey ? rows.findIndex(value => value._id === previewKey) : -1;
    const historyEnd = rows.reduce((last, value, position) => historyKeys.has(value._id) ? position + 1 : last, 0);
    const insert = index >= 0 ? index + 1 : anchor?.after === null ? historyEnd : previewIndex >= 0 ? previewIndex : rows.length;
    rows.splice(insert, 0, row);
    if (anchor) tails.set(anchor.after, row._id);
  }
  return rows;
}

/** Display previously observed ranges without implying the gaps are continuous. */
export function visibleRowsFor(snapshot: ChatControllerSnapshot): TimelineRow[] {
  const current = rowsFor(snapshot);
  if (!snapshot.view || !snapshot.detached.length) return current;
  const ids = new Set([...snapshot.history, ...snapshot.view.messages].map(message => message.id));
  if (snapshot.connection === 'online' && snapshot.view.streamingReply) ids.add(snapshot.view.streamingReply.id);
  const operations = new Set([...snapshot.history, ...snapshot.view.messages].map(message => message.operationId).filter(Boolean));
  for (const item of snapshot.pending) operations.add(item.operationId);
  const groups: TimelineRow[][] = [];
  for (const range of [...snapshot.detached].reverse()) {
    // rowsFor and the message components only read these immutable snapshots.
    const selected = range.messages.filter(message => {
      if (ids.has(message.id) || (message.operationId && operations.has(message.operationId))) return false;
      ids.add(message.id);
      if (message.operationId) operations.add(message.operationId);
      return true;
    }) as ChatMessage[];
    if (!selected.length) continue;
    const rows = rowsFor({ ...snapshot, connection: 'offline', history: [], pending: [], view: { ...snapshot.view, messages: selected } });
    if (!rows.length) continue;
    groups.unshift([...rows, { _id: JSON.stringify(['gap', snapshot.view.sessionId, range.id]), kind: 'gap', text: '', createdAt: 0, user: { _id: 'partner' } }]);
  }
  return [...groups.flat(), ...current];
}

/** Capture placement from the same snapshot the controller checks for admission. */
export function sendPlacement(snapshot: ChatSnapshot): SendPlacement {
  const rows = rowsFor(snapshot);
  const last = rows.at(-1);
  if (last?.pendingState && last.operationId) {
    const pending = snapshot.pending.find(item => item.operationId === last.operationId);
    const after = pending?.anchor ? pending.anchor.after : [...rows].reverse().find(row => !row.pendingState)?._id ?? null;
    return { snapshot, after, predecessor: last.operationId };
  }
  return { snapshot, after: last?._id ?? null };
}

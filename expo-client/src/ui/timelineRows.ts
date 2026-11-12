import type { ChatMessage, FileRef, ImageRef } from '../../vendor/contracts/src/index';
import { isReplySource } from '../../vendor/contracts/src/reply-ranges';
import type { ChatSnapshot } from '../cfl/chat';

export type TimelineRow = { _id: string; text: string; createdAt: number; user: { _id: string }; original?: ChatMessage; pendingState?: 'unknown' | 'submitted' | 'failed'; pendingImages?: ImageRef[]; pendingFiles?: FileRef[] };

/** Show only the source ranges published by the host, using the same keys for preview and history. */
export function rowsFor(snapshot: ChatSnapshot): TimelineRow[] {
  const all = [...snapshot.history, ...(snapshot.view?.messages ?? [])];
  const ids = new Set<string>();
  const operationIds = new Set(all.map(message => message.operationId).filter(Boolean));
  const rows: TimelineRow[] = [];
  const sessionId = snapshot.view?.sessionId ?? '';
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
  for (const item of all) {
    if (ids.has(item.id)) continue;
    ids.add(item.id);
    if (isReplySource(item)) rows.push(...replyRows(item, item));
    else rows.push({ _id: item.id, text: item.text, createdAt: item.createdAt, user: { _id: item.role === 'user' ? 'me' : 'partner' }, original: item });
  }
  const preview = snapshot.connection === 'online' ? snapshot.view?.streamingReply : undefined;
  if (preview && !ids.has(preview.id)) {
    const index = rows.findIndex(row => row.createdAt > preview.createdAt);
    rows.splice(index < 0 ? rows.length : index, 0, ...replyRows(preview));
  }
  for (const item of snapshot.pending) {
    if (operationIds.has(item.operationId)) continue;
    rows.push({ _id: item.operationId, text: item.text, createdAt: item.createdAt, user: { _id: 'me' }, pendingState: item.state, pendingImages: item.images, pendingFiles: item.files });
  }
  return rows;
}

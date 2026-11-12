import { ImageRefSchema, StickerSchema, validate, type ImageRef, type Sticker, type StickerIdentity } from '../../vendor/contracts/src/index';
import type { ChatController, ChatSnapshot } from './chat';

export type RecentSticker = { id: string; version: string; messageId: string; role: 'user' | 'agent'; createdAt: number; image: ImageRef };
export type RecentStickers = { origin: string; sessionId: string; items: RecentSticker[]; current(): boolean };
const owners = new WeakMap<RecentStickers, { controller: ChatController; identities: Map<string, StickerIdentity> }>();
const itemKey = (item: RecentSticker) => JSON.stringify([item.id, item.version, item.messageId, item.image.attachmentId]);

/** Only observed messages currently loaded in this controller; no pending sends or cross-session history. */
export function recentStickers(controller: ChatController): RecentStickers | null {
  const snapshot: ChatSnapshot = controller.snapshot(), view = snapshot.view;
  if (!view) return null;
  const scope = controller.scope();
  const current = () => scope() && controller.snapshot().view?.sessionId === view.sessionId && controller.snapshot().failure !== 'access_denied';
  if (!current()) return null;
  const messages = new Map([...snapshot.history, ...view.messages].map(message => [message.id, message]));
  const candidates = [...messages.values()].flatMap(message => {
    if (message.role !== 'user' && message.role !== 'agent') return [];
    return (message.images ?? []).flatMap((raw, index) => {
      try {
        const image = validate(ImageRefSchema, raw);
        return image.sticker ? [{ id: image.sticker.id, version: image.sticker.version, messageId: message.id, role: message.role as 'user' | 'agent', createdAt: message.createdAt, image, index }] : [];
      } catch { return []; }
    });
  });
  candidates.sort((a, b) => b.createdAt - a.createdAt || (a.messageId < b.messageId ? 1 : a.messageId > b.messageId ? -1 : 0) || b.index - a.index);
  const seen = new Set<string>();
  const items = candidates.filter(item => { if (seen.has(item.id)) return false; seen.add(item.id); return true; }).slice(0, 30).map(({ index: _index, ...item }) => item);
  const result = { origin: controller.origin, sessionId: view.sessionId, items, current };
  owners.set(result, { controller, identities: new Map(items.map(item => [itemKey(item), { id: item.id, version: item.version }])) });
  return result;
}

/** Use immediately for an explicit send; sendSticker/stage checks current server availability. */
export function recentStickerIdentity(controller: ChatController, recent: RecentStickers, item: RecentSticker): StickerIdentity | null {
  const owner = owners.get(recent);
  if (owner?.controller !== controller || controller.origin !== recent.origin || controller.snapshot().view?.sessionId !== recent.sessionId || !recent.current()) return null;
  const observed = owner.identities.get(itemKey(item));
  return observed ? { ...observed } : null;
}

/** Candidates must come from a current StickerClient catalog page; stage still revalidates at send. */
export function resolveRecentSticker(recent: RecentStickers, item: RecentSticker, catalog: readonly Sticker[]): { state: 'ready'; sticker: Sticker } | { state: 'unresolved' | 'unavailable' | 'session_changed' } {
  if (!recent.current()) return { state: 'session_changed' };
  if (!recent.items.includes(item)) return { state: 'unresolved' };
  const found = catalog.find(sticker => sticker.id === item.id && sticker.version === item.version);
  if (!found) return { state: 'unresolved' };
  let valid: Sticker;
  try { valid = validate(StickerSchema, found); } catch { return { state: 'unresolved' }; }
  if (!valid.available) return { state: 'unavailable' };
  return { state: 'ready', sticker: valid };
}

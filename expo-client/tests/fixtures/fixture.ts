import type { ChatMessage, ChatView, Receipt } from '../../vendor/contracts/src/index';
import { ChatController, type ChatPort, type PendingStore } from '../../src/cfl/chat';
import { createFixtureMedia } from './fixture-attachments';

/** Entirely synthetic and process-local: does not open sockets or access any account. */
export function createFixture(options: { newOperationId?: () => string } = {}) {
  const message = (id: string, role: 'user' | 'agent', text: string, createdAt: number): ChatMessage => ({ id, role, text, createdAt, operationId: null, turnId: null });
  const base = Date.UTC(2025, 3, 12, 1, 30);
  const old = [message('fixture-older', 'agent', '上次你说周末想出去走走，后来选好地方了吗？', base - 60000),
    { ...message('fixture-reminder', 'agent', '记得喝水。\n出门前带上雨伞。', base - 30000), source: { kind: 'reminder' as const, reminderId: 'fixture-reminder-id', occurrenceId: 'fixture-occurrence' } }];
  const firstReply = '那就找个不赶时间的地方，慢慢走走吧。';
  let view: ChatView = { version: 2, sessionId: 'fixture-session', name: 'Mica', activeTurnId: null, contextUsage: { tokens: null, capacity: null }, compaction: null,
    messages: [message('fixture-1', 'user', '还在想，最近总觉得有点忙。', base), { ...message('fixture-2', 'agent', firstReply, base + 60000), ends: [firstReply.length] },
      { ...message('fixture-3', 'user', '看到这张风景图，想起上次去湖边的那天。', base + 120000), images: [{ attachmentId: 'fixture-image', mediaType: 'image/png', name: '湖边风景.png', availability: 'available' }] },
      { ...message('fixture-4', 'user', '', base + 180000), files: [{ attachmentId: 'fixture-file', name: 'sample.txt', mediaType: 'text/plain', size: 12, availability: 'available' }] },
      { ...message('fixture-5', 'user', '', base + 240000), images: [{ attachmentId: 'fixture-sticker', mediaType: 'image/png', name: 'sticker.png', availability: 'missing', sticker: { id: 'fixture-sticker', version: '0'.repeat(64) } }] },
      { ...message('fixture-6', 'agent', '', base + 300000), ui: { fixture: true } },
      { ...message('fixture-agent-sticker-message', 'agent', '', base + 360000), imageState: 'ready', images: [{ attachmentId: 'fixture-agent-sticker', mediaType: 'image/png', name: '透明表情.png', availability: 'available', sticker: { id: 'fixture-sticker', version: '0'.repeat(64) } }] }],
    before: 'fixture-older', capabilities: { text: true, steer: true, stop: true, workspaceImages: true, images: { mediaTypes: ['image/png', 'image/jpeg', 'image/webp', 'image/gif'], maxImagesPerMessage: 6, maxImageBytes: 8_000_000, maxMessageImageBytes: 24_000_000 }, files: { maxFilesPerMessage: 6, maxFileBytes: 100_000_000, maxMessageFileBytes: 200_000_000 } } };
  let notify = (_: ChatView) => {};
  const listeners = new Set<(view: ChatView) => void>();
  let notifyReceipt = (_: Receipt) => {};
  const receiptListeners = new Set<(receipt: Receipt) => void>();
  const receipts = new Map<string, { text: string; receipt: Receipt }>();
  let entries: Awaited<ReturnType<PendingStore['load']>> = [];
  const store: PendingStore = { async load() { return entries; }, async save(_, value) { entries = value; } };
  const port: ChatPort = {
    async history() { return { messages: old, before: null }; },
    async search({ query }) {
      const matched = [...old, ...view.messages].filter(item => item.text.includes(query));
      const hits = matched.slice(0, 20).map(item => ({ id: item.id, kind: 'message' as const, sessionId: view.sessionId, role: item.role === 'user' ? 'user' as const : 'assistant' as const, snippet: { segments: [{ text: item.text, highlighted: false }] } }));
      return { hits, estimatedTotalHits: matched.length, limited: matched.length > 20 };
    },
    async searchRead({ id }) {
      const items = [...old, ...view.messages]; const index = items.findIndex(item => item.id === id);
      if (index < 0) throw new Error('fixture_record_missing');
      const record = items[index];
      return { record: { id, kind: 'message' as const, sessionId: view.sessionId, role: record.role === 'user' ? 'user' as const : 'assistant' as const, content: record.text }, context: { targetSourceRecordIndex: index, truncated: false, items: items.slice(Math.max(0, index - 8), index + 9).map((item, offset) => ({ sourceRecordIndex: Math.max(0, index - 8) + offset, kind: 'message' as const, role: item.role === 'user' ? 'user' as const : 'assistant' as const, content: item.text })) } };
    },
    async submit(input) {
      const existing = receipts.get(input.operationId);
      if (existing) {
        if (existing.text !== input.text) throw new Error('fixture_operation_conflict');
        return existing.receipt;
      }
      const receipt: Receipt = { operationId: input.operationId, attempt: 1, state: 'submitted', messageId: `fixture-${input.operationId}`, turnId: null, error: null };
      receipts.set(input.operationId, { text: input.text, receipt });
      const reply = /累|忙/.test(input.text) ? '辛苦了，先给自己一点休息的时间吧。' : /你好|早上好|晚上好/.test(input.text) ? '你好呀，今天过得怎么样？' : '我听到了。我们可以慢慢聊，你现在最想从哪儿说起？';
      const now = Date.now();
      view = { ...view, messages: [...view.messages,
        { ...message(receipt.messageId!, 'user', input.text, now), operationId: input.operationId, ...(input.images ? { images: input.images } : {}), ...(input.files ? { files: input.files } : {}) },
        { ...message(`fixture-reply-${input.operationId}`, 'agent', reply, now + 1), ends: [reply.length] },
      ] }; notify(view); for (const listener of listeners) listener(view);
      notifyReceipt(receipt); for (const listener of receiptListeners) listener(receipt);
      return receipt;
    },
    async lookup(id) { return receipts.get(id)?.receipt ?? null; }, close() {},
  };
  let sequence = 0;
  const controller = new ChatController('fixture://local', async () => ({ close() {} }) as WebSocket, store,
    options.newOperationId ?? (() => `00000000-0000-4000-8000-${String(++sequence).padStart(12, '0')}`),
    async (_, changed, _offline, delivery) => { notify = changed; notifyReceipt = delivery; changed(view); return port; });
  const media = createFixtureMedia();
  return { controller, media, port, read: () => view, subscribe(listener: (view: ChatView) => void) {
    listeners.add(listener); return () => { listeners.delete(listener); };
  }, subscribeReceipts(listener: (receipt: Receipt) => void) {
    receiptListeners.add(listener); return () => { receiptListeners.delete(listener); };
  } };
}

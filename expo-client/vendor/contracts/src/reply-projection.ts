import type { ChatMessage, ChatView, HistoryPage, StreamingReply } from "./index.ts";
import { createReplySegmenter, stableReplySegments } from "./reply-chunks.ts";
import { isReplySource } from "./reply-ranges.ts";

type Source = { id: string; text: string; complete: boolean };
type Active = { segmenter: ReturnType<typeof createReplySegmenter> };
const ends = (text: string, complete: boolean) => stableReplySegments(text, complete).map(segment => segment.end);
const isReply = isReplySource;
const projectItem = (message: ChatMessage): ChatMessage => isReply(message)
  ? { ...message, ends: ends(message.text, message.textState !== "streaming") }
  : message;

/**
 * The caller must supply authority-backed source IDs that remain unique for an
 * attempt and match between the preview and its final/history record. The
 * projection does not infer that association from text or timestamps.
 */
export function createReplyProjection() {
  let sessionId: string | undefined;
  let active = new Map<string, Active>();
  return {
    view(next: ChatView, previous?: ChatView): ChatView {
      const current = sessionId === next.sessionId ? active : new Map<string, Active>();
      const oldMessages = previous?.sessionId === next.sessionId ? previous.messages : [];
      const candidates = new Map<string, Source>();
      const add = (source: Source) => {
        const old = candidates.get(source.id);
        if (old && (old.text !== source.text || old.complete !== source.complete))
          throw new Error("Reply source conflict: inconsistent duplicate");
        candidates.set(source.id, source);
      };
      for (const message of next.messages) {
        if (!isReply(message)) continue;
        const old = oldMessages.find(item => item.id === message.id && isReply(item));
        if (old && old.textState !== "streaming" && (old.text !== message.text || message.textState === "streaming"))
          throw new Error("Reply source conflict: completed source changed");
        const complete = message.textState !== "streaming";
        if (!complete || current.has(message.id)) add({ id: message.id, text: message.text, complete });
      }
      const completedPreview = next.streamingReply && next.messages.some(message =>
        isReply(message) && message.id === next.streamingReply!.id && message.textState !== "streaming");
      if (next.streamingReply && !completedPreview)
        add({ id: next.streamingReply.id, text: next.streamingReply.text, complete: false });
      // Stage every source so a rejected view cannot advance another source.
      const projected = new Map<string, number[]>();
      const keep = new Map<string, Active>();
      for (const source of candidates.values()) {
        const entry = { segmenter: current.get(source.id)?.segmenter.fork() ?? createReplySegmenter() };
        const result = entry.segmenter.update({ sessionId: next.sessionId, sourceId: source.id, attemptId: source.id }, source.text, source.complete);
        if (result.status !== "ok") throw new Error(`Reply source conflict: ${result.status}`);
        projected.set(source.id, result.segments.map(segment => segment.end));
        if (!source.complete) keep.set(source.id, entry);
      }
      const messages = next.messages.map((message): ChatMessage => {
        if (!isReply(message)) return message;
        const prior = oldMessages.find(item => item.id === message.id && isReply(item) && item.textState !== "streaming" && item.text === message.text);
        return { ...message, ends: projected.get(message.id) ?? prior?.ends ?? ends(message.text, message.textState !== "streaming") };
      });
      const duplicatePreview = next.streamingReply && next.messages.some(message => isReply(message) && message.id === next.streamingReply!.id);
      const streamingReply: StreamingReply | undefined = next.streamingReply && !duplicatePreview
        ? { ...next.streamingReply, ends: projected.get(next.streamingReply.id)! }
        : undefined;
      sessionId = next.sessionId;
      active = keep;
      const { streamingReply: _rawPreview, ...rest } = next;
      return { ...rest, messages, ...(streamingReply ? { streamingReply } : {}) };
    },
    history(page: HistoryPage, current: ChatView, initial: ChatView): HistoryPage {
      // Compare only the source itself; image, delivery and other metadata may change.
      const referenceIn = (view: ChatView, id: string) => {
        const message = view.messages.find(item => item.id === id && isReply(item));
        if (message) return message;
        if (view.streamingReply?.id === id)
          return { text: view.streamingReply.text, textState: "streaming" as const, ends: view.streamingReply.ends };
      };
      const projected = page.messages.map(projectItem);
      for (const message of projected) {
        if (!isReply(message)) continue;
        const reference = referenceIn(current, message.id) ?? referenceIn(initial, message.id);
        const ends = reference?.ends ?? [];
        const publishedEnd = ends.at(-1) ?? 0;
        if (reference && (reference.textState !== "streaming"
          ? reference.text !== message.text || message.textState === "streaming"
          : reference.text.slice(0, publishedEnd) !== message.text.slice(0, publishedEnd) ||
            ends.some((end, index) => message.ends?.[index] !== end)))
          throw new Error("Reply source conflict: history differs from view");
      }
      return { ...page, messages: projected };
    },
    clear() { active.clear(); sessionId = undefined; },
  };
}

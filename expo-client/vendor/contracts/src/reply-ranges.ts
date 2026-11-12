import type { ChatMessage } from "./index.ts";

/** The host projects ordinary assistant replies, not user, external or media records. */
export function isReplySource(message: ChatMessage): boolean {
  return message.role === "agent" && message.source === undefined &&
    message.imageState === undefined && message.voice === undefined &&
    message.ui === undefined;
}

/** Validate source-relative UTF-16 ends before a consumer slices the source. */
export function validateReplyEnds(text: string, ends: number[]): number[] {
  let previous = 0;
  for (const end of ends) {
    if (!Number.isSafeInteger(end) || end <= previous || end > text.length)
      throw new Error("Invalid reply segment boundary");
    const before = text.charCodeAt(end - 1), after = text.charCodeAt(end);
    if (before >= 0xd800 && before <= 0xdbff && after >= 0xdc00 && after <= 0xdfff)
      throw new Error("Invalid reply segment boundary");
    previous = end;
  }
  return ends;
}

export function validateReplySource(source: { text: string; ends?: number[] }, required = false): void {
  if (required && source.ends === undefined) throw new Error("Missing reply segment boundaries");
  if (source.ends !== undefined) validateReplyEnds(source.text, source.ends);
}

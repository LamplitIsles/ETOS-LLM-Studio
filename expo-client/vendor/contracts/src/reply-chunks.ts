import { Lexer, type Token } from "marked";

export interface ReplyChunk {
  start: number;
  end: number;
  /** Exact UTF-16 source span, including original whitespace/quote markers. */
  text: string;
  /** Shared-reference, math-aware render projection; never copied or persisted. */
  tokens: Token[];
}

const hasContent = (raw: string) =>
  raw.replace(/^ {0,3}>[ \t]?/gm, "").trim().length > 0;

export function replyChunks(
  source: string,
  parse: (source: string) => Token[] = (source) =>
    Lexer.lex(source, { gfm: true }),
  clean: (tokens: Token[]) => Token[] = (tokens) => tokens,
  streaming = false,
): ReplyChunk[] {
  // Hold the unfinished source line before parsing, so partial Markdown cannot
  // change the visible structure. Final/history callers retain the exact tail.
  if (streaming) source = source.slice(0, source.lastIndexOf("\n") + 1);
  if (!source) return [];
  // Marked normalizes line endings. Keep a boundary map back to original UTF-16.
  let text = "";
  const original = [0];
  for (let i = 0; i < source.length; i++) {
    text += source[i] === "\r" ? "\n" : source[i];
    if (source[i] === "\r" && source[i + 1] === "\n") i++;
    original.push(i + 1);
  }
  if (!hasContent(text)) return [];
  // Boundary detection and clipping use only pre-cleanup source tokens.
  const parsed = parse(text);
  const starts = [0];
  const leaves: { token: Token; map: number[]; wrappers: Token[] }[] = [];
  const add = (at: number) => {
    const last = starts.at(-1)!;
    if (at <= last || at >= text.length) return;
    const raw = text.slice(last, at);
    if (hasContent(raw)) starts.push(at);
  };
  function prose(raw: string, inlines: Token[], map: number[]) {
    // Newlines inside a complete inline token belong to that local structure.
    // An open delimiter protects only the paragraph's unfinished tail.
    const protectedSpans: [number, number][] = [];
    const html: { tag: string; start: number }[] = [];
    let offset = 0;
    for (const inline of inlines) {
      if (!raw.startsWith(inline.raw, offset)) return;
      // Marked emits inline HTML opens/closes separately. Keep their required
      // source context together so cleanup sees the same pair as whole mode.
      if (inline.type === "html") {
        const tag = inline.raw.match(/^<(\/?)([a-zA-Z][\w-]*)(?=[\s/>])/);
        if (
          tag &&
          !inline.raw.endsWith("/>") &&
          !/^(br|hr|img|input|link|meta|area|base|col|embed|keygen|param|source|track|wbr)$/i.test(
            tag[2],
          )
        ) {
          if (!tag[1]) html.push({ tag: tag[2], start: offset });
          else {
            const open = html.pop();
            if (open?.tag === tag[2])
              protectedSpans.push([open.start, offset + inline.raw.length]);
          }
        }
      }
      if (inline.type !== "text")
        protectedSpans.push([offset, offset + inline.raw.length]);
      else {
        let consumed = 0;
        for (const match of inline.raw.matchAll(
          /\*\*|__|(?<![\p{L}\p{N}])[*_](?=\S)|`+|\[/gu,
        )) {
          if (match.index < consumed) continue;
          const marker = match[0];
          const close = inline.raw.indexOf(
            marker === "[" ? "]" : marker,
            match.index + marker.length,
          );
          if (
            close < 0 ||
            (marker === "[" &&
              inline.raw[close + 1] === "(" &&
              !inline.raw.includes(")", close + 2))
          ) {
            protectedSpans.push([offset + match.index, raw.length]);
            break;
          }
          consumed = close + marker.length;
        }
      }
      offset += inline.raw.length;
    }
    for (const open of html) protectedSpans.push([open.start, raw.length]);
    for (const newline of raw.matchAll(/\n/g)) {
      const end = newline.index + 1;
      if (
        end < raw.length &&
        !protectedSpans.some(([start, stop]) => start < end && end < stop)
      )
        add(map[end]);
    }
  }

  function blocks(
    tokens: Token[],
    raw: string,
    map: number[],
    wrappers: Token[] = [],
  ) {
    let cursor = 0;
    let seenBlock = false;
    for (const token of tokens) {
      const at = raw.indexOf(token.raw, cursor);
      if (at < 0) return; // Unmappable unusual syntax stays in its current block.
      cursor = at + token.raw.length;
      if (token.type === "space" || token.type === "def") continue;
      if (seenBlock) add(map[at]);
      seenBlock = true;
      if (token.type === "paragraph" && token.tokens) {
        leaves.push({ token, map: map.slice(at, cursor + 1), wrappers });
        prose(token.raw, token.tokens, map.slice(at, cursor + 1));
      } else if (token.type === "blockquote" && token.tokens) {
        // Remove one quote level while retaining every source boundary. Lazy
        // continuation lines have no prefix to remove; nested quotes recurse.
        let body = "";
        const bodyMap: number[] = [];
        let lineAt = 0;
        for (const line of token.raw.match(/[^\n]*\n|[^\n]+$/g) ?? []) {
          const prefix = line.match(/^ {0,3}>[ \t]?/)?.[0].length ?? 0;
          for (let i = prefix; i < line.length; i++) {
            bodyMap.push(map[at + lineAt + (i === prefix ? 0 : i)]);
            body += line[i];
          }
          lineAt += line.length;
        }
        bodyMap.push(map[cursor]);
        if (body.trimEnd() === token.text.trimEnd()) {
          blocks(token.tokens, body, bodyMap, [...wrappers, token]);
        } else leaves.push({ token, map: map.slice(at, cursor + 1), wrappers });
      } else leaves.push({ token, map: map.slice(at, cursor + 1), wrappers });
    }
  }
  blocks(
    parsed,
    text,
    Array.from({ length: text.length + 1 }, (_, i) => i),
  );
  // Blank lines and empty quote lines never open an empty display message.
  if (starts.length > 1 && !hasContent(text.slice(starts.at(-1)!)))
    starts.pop();
  return starts.map((at, index) => {
    const end = starts[index + 1] ?? text.length;
    const tokens = leaves.flatMap(({ token, map, wrappers }) => {
      if (map[0] >= end || map.at(-1)! <= at) return [];
      let projected = token;
      if (token.type === "paragraph" && token.tokens) {
        const from =
          at <= map[0] ? 0 : map.findIndex((position) => position >= at);
        const stop =
          end >= map.at(-1)!
            ? token.raw.length
            : map.findIndex((position) => position >= end);
        const raw = token.raw.slice(from, stop).replace(/\n+$/, "");
        const limit = from + raw.length;
        let offset = 0;
        const inlines = token.tokens.flatMap((inline) => {
          const start = offset;
          offset += inline.raw.length;
          const left = Math.max(from, start),
            right = Math.min(limit, offset);
          if (left >= right) return [];
          if (left === start && right === offset) return [inline];
          const raw = inline.raw.slice(left - start, right - start);
          return [{ ...inline, raw, text: raw }];
        });
        projected = { ...token, raw, text: raw, tokens: inlines };
      }
      for (const wrapper of [...wrappers].reverse()) {
        projected = {
          ...wrapper,
          raw: projected.raw,
          text: projected.raw,
          tokens: [projected],
        };
      }
      return [projected];
    });
    return {
      start: original[at],
      end: original[end],
      text: source.slice(original[at], original[end]),
      tokens: clean(tokens),
    };
  });
}

/** A stable slice of the original UTF-16 source. */
export interface ReplySegment {
  readonly start: number;
  readonly end: number;
  readonly text: string;
}

/** The identity must come from the source authority, not text or timestamps. */
export interface ReplySegmentIdentity {
  sessionId: string;
  sourceId: string;
  attemptId: string;
}

export type ReplySegmentUpdate =
  | { status: "ok"; segments: ReplySegment[] }
  | { status: "conflict"; segments: ReplySegment[] }
  | { status: "identity-changed"; segments: ReplySegment[] };

type Block =
  | { kind: "fence"; from: number; end: number; close: RegExp }
  | { kind: "math"; from: number; end: number; close: string }
  | { kind: "header" | "table" | "list"; from: number; end: number };
type Snapshot = {
  identity: ReplySegmentIdentity | undefined;
  previous: string;
  cursor: number;
  searchFrom: number;
  finished: boolean;
  segments: ReplySegment[];
  blankStart: number | undefined;
  block: Block | undefined;
};
type Segmenter = {
  update(next: ReplySegmentIdentity, source: string, complete: boolean): ReplySegmentUpdate;
  /** Copy transient state for an atomic host view update. */
  fork(): Segmenter;
};
function createSegmenter(snapshot?: Snapshot): Segmenter {
  let identity = snapshot?.identity;
  let previous = snapshot?.previous ?? "", cursor = snapshot?.cursor ?? 0, searchFrom = snapshot?.searchFrom ?? 0;
  let finished = snapshot?.finished ?? false;
  let segments: ReplySegment[] = snapshot?.segments.slice() ?? [];
  let blankStart = snapshot?.blankStart;
  let block = snapshot?.block && { ...snapshot.block };
  const body = (line: string) => line.replace(/^ {0,3}(?:>[ \t]?)+/, "");
  const blank = (line: string) => !hasContent(line);
  const fence = (line: string) => body(line).match(/^ {0,3}(`{3,}|~{3,})(.*)$/);
  const tableHeader = (line: string) => /^ {0,3}\|/.test(body(line));
  const tableRow = (line: string) => body(line).includes("|");
  const tableRule = (line: string) => /^ {0,3}\|?[ \t]*:?-{3,}:?[ \t]*(?:\|[ \t]*:?-{3,}:?[ \t]*)+\|?[ \t]*$/.test(body(line)) || /^ {0,3}\|[ \t]*:?-{3,}:?[ \t]*\|[ \t]*$/.test(body(line));
  const list = (line: string) => /^ {0,3}(?:[-+*]|\d{1,9}[.)])[ \t]+/.test(body(line));
  const sameIdentity = (a: ReplySegmentIdentity, b: ReplySegmentIdentity) =>
    a.sessionId === b.sessionId && a.sourceId === b.sourceId && a.attemptId === b.attemptId;
  const reset = (next: ReplySegmentIdentity) => {
    identity = { ...next }; previous = ""; cursor = 0; searchFrom = 0;
    finished = false; segments = []; blankStart = undefined; block = undefined;
  };
  const emit = (source: string, from: number, to: number, math = false) => {
    const raw = source.slice(from, to);
    if (math) {
      if (hasContent(raw)) segments.push(Object.freeze({ start: from, end: to, text: raw }));
    } else {
      for (const chunk of replyChunks(raw))
        segments.push(Object.freeze({ start: from + chunk.start, end: from + chunk.end, text: chunk.text }));
    }
  };
  const line = (source: string, start: number, end: number) => {
    const text = source.slice(start, end).replace(/\r?\n$/, "");
    // A boundary line may end a table/list or reject a header; process that
    // same line again outside the closed block.
    if (block) {
      const current = block;
      if (current.kind === "fence" || current.kind === "math") {
        current.end = end;
        const closed = current.kind === "fence"
          ? current.close.test(body(text)) : body(text).trim() === current.close;
        if (closed) {
          emit(source, current.from, end, current.kind === "math");
          block = undefined;
        }
        return;
      }
      if (current.kind === "header" && tableRule(text)) {
        block = { kind: "table", from: current.from, end };
        return;
      }
      if (current.kind === "table" && !blank(text) && tableRow(text)) {
        current.end = end;
        return;
      }
      if (current.kind === "list" && !blank(text) && (list(text) || /^ {2,}\S/.test(body(text)))) {
        current.end = end;
        return;
      }
      emit(source, current.from, current.end);
      block = undefined;
    }
    if (blank(text)) { blankStart ??= start; return; }
    const from = blankStart ?? start;
    blankStart = undefined;
    const math = body(text).match(/^ {0,3}(\$\$|\\\[)[ \t]*$/);
    if (math) {
      block = { kind: "math", from, end, close: math[1] === "$$" ? "$$" : "\\]" };
      return;
    }
    const open = fence(text);
    if (open) {
      const marker = open[1]!, char = marker[0]!;
      block = { kind: "fence", from, end,
        close: new RegExp(`^ {0,3}${char === "`" ? "`" : "~"}{${marker.length},}[ \\t]*$`) };
      return;
    }
    if (tableHeader(text)) { block = { kind: "header", from, end }; return; }
    if (list(text)) { block = { kind: "list", from, end }; return; }
    emit(source, from, end);
  };
  const check = (next: ReplySegmentIdentity, source: string, complete: boolean): ReplySegmentUpdate["status"] => {
    if (identity && !sameIdentity(identity, next)) return "identity-changed";
    if (finished && (!complete || source !== previous)) return "conflict";
    const publishedEnd = segments.at(-1)?.end ?? 0;
    if (source.slice(0, publishedEnd) !== previous.slice(0, publishedEnd)) return "conflict";
    return "ok";
  };
  return {
    fork() {
      return createSegmenter({ identity, previous, cursor, searchFrom, finished, segments, blankStart, block });
    },
    update(next: ReplySegmentIdentity, source: string, complete: boolean): ReplySegmentUpdate {
      const status = check(next, source, complete);
      if (status === "identity-changed") return { status, segments: [] };
      if (status === "conflict") return { status, segments: segments.slice() };
      if (!identity) reset(next);
      if (finished) return { status: "ok", segments: segments.slice() };
      if (!source.startsWith(previous)) {
        // A block or blank tail may already have consumed lines without emitting.
        cursor = segments.at(-1)?.end ?? 0;
        searchFrom = cursor;
        blankStart = undefined;
        block = undefined;
      }
      while (cursor < source.length) {
        const lf = source.indexOf("\n", searchFrom);
        if (lf < 0 && !complete) { searchFrom = source.length; break; }
        const end = lf < 0 ? source.length : lf + 1;
        line(source, cursor, end);
        cursor = end;
        searchFrom = cursor;
      }
      previous = source;
      if (complete) {
        if (block) emit(source, block.from, block.end, block.kind === "math");
        block = undefined;
        finished = true;
      }
      return { status: "ok", segments: segments.slice() };
    },
  };
}

/**
 * One short-lived projection bound to the first identity. A changed identity
 * is rejected without disclosing the old segments; the caller creates a new
 * projection and fences obsolete updates. The unpublished tail can be
 * rewritten; changes to published segments are rejected. The caller owns
 * disposal.
 */
export function createReplySegmenter(): Segmenter {
  return createSegmenter();
}

/** Project a complete source without retaining incremental state. */
export function stableReplySegments(source: string, complete: boolean): ReplySegment[] {
  return createReplySegmenter().update({ sessionId: "", sourceId: "", attemptId: "" }, source, complete).segments;
}

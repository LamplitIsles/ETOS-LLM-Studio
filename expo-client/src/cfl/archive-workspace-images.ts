import { Marked, type Token } from 'marked';
import { workspaceImageUrl } from '../../vendor/contracts/src/workspace-images';
import { isWorkspaceImageGet } from './workspace-image-query';

// Search records can be much larger than context items. Never parse unbounded
// text or implicitly request an unbounded number of workspace files.
const MAX_SOURCE = 131_072;
const MAX_IMAGES = 16;
const OPEN = /<image name=\[Image #([1-9]\d{0,5})\] path="([^"<>\r\n]{1,4096})">$/u;
const UNSAFE_TEXT = /[<>\\\[\]()*_~`!]/u;
const parser = new Marked({ gfm: true });

export type ArchiveWorkspaceImage = Readonly<{
  /** UTF-16 offsets into the unchanged search record; never split Markdown at these offsets. */
  start: number;
  end: number;
  /** Untrusted literal path, supplied by the archive, not a message attachment identity. */
  path: string;
  /** Canonical workspace-image URL; still subject to the authenticated server's checks. */
  requestPath: string;
}>;
export type ArchiveWorkspaceImages = Readonly<{
  status: 'ok' | 'unavailable' | 'limit' | 'unsupported';
  images: readonly ArchiveWorkspaceImage[];
}>;
type Options = { workspaceImages: boolean; isCurrent: () => boolean; signal?: AbortSignal };

function check(options: Options) {
  if (!options.isCurrent()) throw new Error('session_changed');
  if (options.signal?.aborted) throw Object.assign(new Error('aborted'), { name: 'AbortError' });
}

/**
 * Identify the unambiguous, empty Codex local-image marker in ordinary, top-level
 * Markdown paragraphs. This is metadata only: keep the original Markdown intact.
 * Markers inside formatted spans, code, links, HTML, lists, and blockquotes are
 * intentionally not interpreted. No filesystem or network operation happens here.
 */
export function findArchiveWorkspaceImages(source: string, options: Options): ArchiveWorkspaceImages {
  check(options);
  if (!options.workspaceImages) return { status: 'unavailable', images: [] };
  if (source.length > MAX_SOURCE) return { status: 'limit', images: [] };

  let blocks: Token[];
  try { blocks = parser.lexer(source); } catch { return { status: 'unsupported', images: [] }; }
  // Marked normalizes CRLF, among other cases. Do not guess original offsets.
  if (blocks.map(block => block.raw).join('') !== source) return { status: 'unsupported', images: [] };
  const images: ArchiveWorkspaceImage[] = [];
  let blockOffset = 0;
  for (const block of blocks) {
    if (block.type === 'paragraph' && Array.isArray(block.tokens)) {
      const tokens = block.tokens;
      const raw = tokens.map((token: Token) => token.raw).join('');
      if (!block.raw.startsWith(raw)) return { status: 'unsupported', images: [] };
      const found: ArchiveWorkspaceImage[] = [];
      let offset = 0;
      let safe = true;
      for (let index = 0; index < tokens.length; index++) {
        const token = tokens[index] as Token;
        if (token.type === 'html') { safe = false; break; }
        // Ambiguous parsing beside inline code/escapes is not worth turning a
        // quoted example into a request. Skip this entire paragraph.
        if (token.type === 'escape' || token.type === 'codespan') { safe = false; break; }
        if (token.type === 'text') {
          const match = OPEN.exec(token.raw);
          const next = tokens[index + 1] as Token | undefined;
          if (match && next?.type === 'html' && next.raw === '</image>') {
            if (UNSAFE_TEXT.test(token.raw.slice(0, match.index))) { safe = false; break; }
            const path = match[2]!;
            let requestPath: string | null = null;
            // The archive path is a literal filesystem path, not an encoded
            // Markdown destination. Encode first so '%' remains a literal '%'.
            try { requestPath = workspaceImageUrl(encodeURIComponent(path)); } catch { /* invalid Unicode */ }
            if (requestPath && isWorkspaceImageGet(requestPath)) {
              const start = blockOffset + offset + match.index;
              found.push({ start, end: blockOffset + offset + token.raw.length + next.raw.length, path, requestPath });
            }
            offset += token.raw.length + next.raw.length;
            index++;
            continue;
          }
          if (UNSAFE_TEXT.test(token.raw)) { safe = false; break; }
        }
        offset += token.raw.length;
      }
      if (safe) images.push(...found);
      if (images.length > MAX_IMAGES) return { status: 'limit', images: [] };
    }
    blockOffset += block.raw.length;
  }
  check(options);
  return { status: 'ok', images };
}

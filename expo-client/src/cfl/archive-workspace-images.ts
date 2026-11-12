import { workspaceImageUrl } from '../../vendor/contracts/src/workspace-images';
import { isWorkspaceImageGet } from './workspace-image-query';

// Search records can be much larger than context items. Never parse unbounded
// text or implicitly request an unbounded number of workspace files.
const MAX_SOURCE = 131_072;
const MAX_IMAGES = 16;
// Accept the Codex label shape and a path-only opening tag.
const OPEN = /<image(?:[ \t]+name=\[Image #[1-9]\d{0,5}\])?[ \t]+path="([^"<>\r\n]{1,4096})"[ \t]*>/gu;
const CLOSE = '</image>';

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
 * Identify unambiguous paired local-image markers anywhere in a search record,
 * including inside Markdown or code. This is metadata only: keep the original
 * Markdown intact. No filesystem or network operation happens here.
 */
export function findArchiveWorkspaceImages(source: string, options: Options): ArchiveWorkspaceImages {
  check(options);
  if (!options.workspaceImages) return { status: 'unavailable', images: [] };
  if (source.length > MAX_SOURCE) return { status: 'limit', images: [] };

  const images: ArchiveWorkspaceImage[] = [];
  const openings = new RegExp(OPEN.source, OPEN.flags);
  let count = 0;
  for (let match = openings.exec(source); match; match = openings.exec(source)) {
    if (++count > MAX_IMAGES) return { status: 'limit', images: [] };
    const close = source.indexOf(CLOSE, openings.lastIndex);
    if (close < 0) break;
    const nested = source.indexOf('<image', openings.lastIndex);
    if (nested >= 0 && nested < close) {
      // Don't guess how an outer image containing another opening is paired.
      openings.lastIndex = nested;
      continue;
    }
    const end = close + CLOSE.length;
    openings.lastIndex = end;
    const path = match[1]!;
    let requestPath: string | null = null;
    // The archive path is a literal filesystem path, not an encoded
    // Markdown destination. Encode first so '%' remains a literal '%'.
    try { requestPath = workspaceImageUrl(encodeURIComponent(path)); } catch { /* invalid Unicode */ }
    if (requestPath && isWorkspaceImageGet(requestPath)) {
      images.push({ start: match.index, end, path, requestPath });
    }
  }
  check(options);
  return { status: 'ok', images };
}

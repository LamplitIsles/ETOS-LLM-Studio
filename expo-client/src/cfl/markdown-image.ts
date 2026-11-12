import { workspaceImageUrl } from '../../vendor/contracts/src/workspace-images';
import { externalImageFetch } from './external-image-fetch';
import { readBoundedBody, type ApiTransport, type ImageData } from './transport';
import { isWorkspaceImageGet } from './workspace-image-query';

const maxBytes = 20 * 1024 * 1024;
const apiImage = /^\/api\/(?:images\/[a-f0-9]{64}|conversation-images\/[a-f0-9]{64}|chat\/media\/[A-Za-z0-9_-]{1,100}\/(?:preview|original|model)|stickers\/media\/[a-f0-9]{64}\/(?:thumbnail|original)|avatars\/(?:companion|user)|backgrounds\/(?:landscape|portrait))$/;

type Scope = { isCurrent: () => boolean; signal?: AbortSignal };
type ImageOptions = Scope & {
  workspaceImages: boolean;
};

function checkScope(options: Scope) {
  if (!options.isCurrent()) throw new Error('session_changed');
  if (options.signal?.aborted) throw Object.assign(new Error('aborted'), { name: 'AbortError' });
}

/** Classify original Markdown destinations before decoding. Only Web may hand an external URL directly to img. */
export function classifyMarkdownImage(source: string, origin: string, options: ImageOptions):
  { kind: 'api'; path: string } | { kind: 'external'; url: string } {
  checkScope(options);
  const allowedApi = (path: string) => apiImage.test(path) || (options.workspaceImages && isWorkspaceImageGet(path));
  if (source !== source.trim() && /^https?:/i.test(source.trim())) throw new Error('invalid_media');
  if (/^https?:\/\//i.test(source)) {
    // Retain the raw path/query for allowlisting: URL parsing normalizes dot segments.
    const parts = /^(https?):\/\/([^/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$/i.exec(source);
    if (!parts || !parts[2] || parts[2].includes('@') || source !== source.trim() ||
        /[\u0000-\u0020\u007f-\u009f\\]/u.test(source) || /%(?![a-f\d]{2})|%(?:0[\da-f]|1[\da-f]|7f)|%c2%(?:8[\da-f]|9[\da-f])/i.test(source)) throw new Error('invalid_media');
    let url: URL, configured: URL;
    try { url = new URL(source); configured = new URL(origin); } catch { throw new Error('invalid_media'); }
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || !['http:', 'https:'].includes(configured.protocol)) throw new Error('invalid_media');
    if (url.origin !== configured.origin) return { kind: 'external', url: url.toString() };
    const path = parts[3] + (parts[4] ?? '');
    if (parts[5] !== undefined || !allowedApi(path)) throw new Error('invalid_media');
    return { kind: 'api', path };
  }
  const path = source.startsWith('/api/')
    ? (allowedApi(source) ? source : null)
    : (options.workspaceImages ? workspaceImageUrl(source) : null);
  if (!path) throw new Error('invalid_media');
  return { kind: 'api', path };
}

/** Fetch authenticated or external bytes with MIME, size, redirect and scope limits. */
export async function loadMarkdownImage(source: string, transport: ApiTransport, options: ImageOptions & {
  /** Test seam; never use the authenticated transport for external requests. */
  externalFetch?: typeof fetch;
}): Promise<ImageData> {
  const check = () => checkScope(options);
  check();
  let response: Response;
  try {
    const destination = classifyMarkdownImage(source, transport.origin, options);
    response = destination.kind === 'external'
      ? await (options.externalFetch ?? externalImageFetch)(destination.url, { credentials: 'omit', redirect: 'error', signal: options.signal })
      : await transport.request(destination.path, { method: 'GET', signal: options.signal });
    try { check(); } catch (error) { await response.body?.cancel().catch(() => {}); throw error; }
    if (response.status === 401 || response.status === 403) throw new Error('access_denied');
    if (response.status === 404) throw new Error('missing');
    if (!response.ok || response.redirected) throw new Error('unavailable');
    const contentType = response.headers.get('content-type')?.split(';')[0].trim().toLowerCase() ?? '';
    if (!['image/png', 'image/jpeg', 'image/webp', 'image/gif'].includes(contentType)) throw new Error('invalid_media');
    const data = await readBoundedBody(response, maxBytes, () => options.isCurrent() && !options.signal?.aborted, 'invalid_media');
    check();
    return { bytes: data, contentType };
  } catch (error) { check(); throw error; }
}

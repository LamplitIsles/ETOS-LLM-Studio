import type { NativeAuth } from './native-auth';
import { httpsOrigin } from './native-auth';

export interface MediaTransport { origin: string; read(path: string, init?: RequestInit): Promise<Response> }
export interface ApiTransport extends MediaTransport { request(path: string, init?: RequestInit): Promise<Response> }
/** Authenticated requests must never leave the configured origin or follow redirects. */
export function nativeTransport(originInput: string, auth: NativeAuth, fetcher: typeof fetch) {
  const origin = httpsOrigin(originInput);
  async function headers() { return { Authorization: `Bearer ${await auth.tokenFor(origin)}`, Origin: origin }; }
  return {
    origin,
    async socket(): Promise<WebSocket> {
      const url = new URL('/api/chat/socket', origin); url.protocol = 'wss:';
      const Socket = WebSocket as unknown as new (url: string, protocols: string[], options: { headers: Record<string, string> }) => WebSocket;
      return new Socket(url.toString(), [], { headers: await headers() });
    },
    async checkAuthorization() {
      const status = async () => {
        const response = await fetcher(`${origin}/api/auth/status`, { headers: await headers(), redirect: 'error' });
        if (!response.ok || response.redirected) throw new Error('unavailable');
        const value = await response.json();
        if (value.mode !== 'passkey' || !['setup', 'signed_out', 'signed_in'].includes(value.state)) throw new Error('unavailable');
        return value.state as 'setup' | 'signed_out' | 'signed_in';
      };
      const state = await status();
      if (state === 'signed_in') return true;
      if (state === 'setup') return false;
      await auth.tokenFor(origin, true);
      return (await status()) === 'signed_in';
    },
    async request(path: string, init: RequestInit = {}) {
      const url = new URL(path, origin);
      if (url.origin !== origin || !url.pathname.startsWith('/api/') || url.hash) throw new Error('invalid_media');
      const requestHeaders = new Headers(init.headers); const authHeaders = await headers();
      requestHeaders.set('Authorization', authHeaders.Authorization); requestHeaders.set('Origin', origin);
      return fetcher(url.toString(), { ...init, headers: requestHeaders, credentials: 'omit', redirect: 'error' });
    },
    async read(path: string, init?: RequestInit) { return this.request(path, init); },
  };
}
export function webTransport(origin: string) {
  if (typeof window === 'undefined' || window.location.origin !== origin || new URL(origin).protocol !== 'https:') throw new Error('same_origin_required');
  return {
    origin,
    async socket(): Promise<WebSocket> { const url = new URL('/api/chat/socket', origin); url.protocol = 'wss:'; return new WebSocket(url.toString()); },
    async checkAuthorization() {
      const response = await fetch('/api/auth/status', { credentials: 'same-origin', cache: 'no-store', redirect: 'error' });
      if (!response.ok || response.redirected) throw new Error('unavailable');
      const value = await response.json();
      if (value.mode !== 'passkey' || !['setup', 'signed_out', 'signed_in'].includes(value.state)) throw new Error('unavailable');
      return value.state === 'signed_in';
    },
    async request(path: string, init: RequestInit = {}) { const url = new URL(path, origin); if (url.origin !== origin || !url.pathname.startsWith('/api/') || url.hash) throw new Error('invalid_media'); return fetch(url.toString(), { ...init, credentials: 'same-origin', redirect: 'error' }); },
    async read(path: string, init?: RequestInit) { return this.request(path, init); },
  };
}
export type ImageData = { bytes: Uint8Array; contentType: string };
export async function loadImage(transport: MediaTransport, attachmentId: string, isCurrent: () => boolean, variant: 'preview' | 'original' = 'preview', signal?: AbortSignal): Promise<ImageData> {
  if (!/^[A-Za-z0-9_-]{1,100}$/.test(attachmentId) || (variant !== 'preview' && variant !== 'original') || !isCurrent()) throw new Error('invalid_media');
  const get = (variant: string) => transport.read(`/api/chat/media/${attachmentId}/${variant}`, { signal });
  let response = await get(variant);
  if (!isCurrent()) { await response.body?.cancel().catch(() => {}); throw new Error('session_changed'); }
  if (variant === 'preview' && response.status === 404) response = await get('original');
  if (!isCurrent()) { await response.body?.cancel().catch(() => {}); throw new Error('session_changed'); }
  if (response.status === 401 || response.status === 403) throw new Error('access_denied');
  if (response.status === 404) throw new Error('missing');
  if (!response.ok || response.redirected) throw new Error('unavailable');
  const contentType = response.headers.get('content-type')?.split(';')[0].toLowerCase() ?? '';
  if (!['image/png', 'image/jpeg', 'image/webp', 'image/gif'].includes(contentType)) throw new Error('invalid_media');
  return { bytes: await readBoundedBody(response, 8_000_000, isCurrent, 'invalid_media'), contentType };
}

/** Read the entire response within a size and session bound, including chunked responses. */
export async function readBoundedBody(response: Response, limit: number, isCurrent: () => boolean, invalid: string, allowEmpty = false): Promise<Uint8Array> {
  const rawLength = response.headers.get('content-length');
  if (!response.body) throw new Error(invalid);
  const reader = response.body.getReader(); const chunks: Uint8Array[] = []; let size = 0;
  try {
    if (rawLength !== null && (!/^\d+$/.test(rawLength) || Number(rawLength) > limit)) throw new Error(invalid);
    for (;;) {
      if (!isCurrent()) throw new Error('session_changed');
      const { done, value } = await reader.read();
      if (!isCurrent()) throw new Error('session_changed');
      if (done) break;
      size += value.byteLength;
      if (size > limit) throw new Error(invalid);
      chunks.push(value);
    }
    if (!size && !allowEmpty) throw new Error(invalid);
    const bytes = new Uint8Array(size); let offset = 0;
    for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
    return bytes;
  } catch (error) {
    await reader.cancel().catch(() => {});
    if (!isCurrent()) throw new Error('session_changed');
    throw error;
  }
}

import { StickerPageRequestSchema, StickerPackRequestSchema, StickerPackPageSchema, StickerPageSchema, StickerFavoriteSchema, StickerFavoriteImageSchema, StickerFavoriteResultSchema, ImageRefSchema, StickerStageSchema, validateStickerStageResult, stickerMediaUrl, validate, type StickerIdentity, type StickerPage, type StickerPackPage, type StickerFavoriteResult, type ImageRef } from '../../vendor/contracts/src/index';
import { readBoundedBody, type ApiTransport, type ImageData } from './transport';
import type { StickerCache } from './sticker-cache-store';

export type StickerPageKind = 'packs' | 'pack' | 'favorites' | 'search';
type PageOptions = { cursor?: string | null; limit?: number; query?: string; packId?: string };
export class StickerClient {
  private denied = false;
  constructor(private transport: ApiTransport, private sessionId: string, private current: () => boolean, private signal?: AbortSignal, private cache?: StickerCache) {}
  private check() {
    if (!this.current()) throw new Error('session_changed');
    if (this.signal?.aborted) throw Object.assign(new Error('aborted'), { name: 'AbortError' });
  }
  private active = () => this.current() && !this.signal?.aborted && !this.denied;
  private key(...parts: unknown[]) { return JSON.stringify(['sticker-cache-v1', this.transport.origin, this.sessionId, ...parts]); }
  private save(key: string, value: unknown) {
    try { void this.cache?.put(key, JSON.stringify(value), this.active).catch(() => {}); } catch { /* cache unavailable */ }
  }
  private async cached(key: string): Promise<unknown | null> {
    this.check();
    if (this.denied) throw new Error('access_denied');
    let value: string | null = null;
    try { value = await this.cache?.get(key) ?? null; } catch { /* cache unavailable */ }
    this.check();
    if (this.denied) throw new Error('access_denied');
    if (value === null || value.length > 1024 * 1024) return null;
    try { return JSON.parse(value) as unknown; } catch { return null; }
  }
  private async json(path: string, init?: RequestInit) {
    try {
      this.check(); const response = await this.transport.request(path, { ...init, signal: this.signal }); this.check();
      if (response.status === 401 || response.status === 403) { this.denied = true; throw new Error('access_denied'); }
      if (!response.ok || response.redirected) throw new Error('sticker_unavailable');
      const bytes = await readBoundedBody(response, 1024 * 1024, () => this.current() && !this.signal?.aborted, 'invalid_sticker');
      this.check();
      try { return JSON.parse(new TextDecoder().decode(bytes)) as unknown; } catch { throw new Error('invalid_sticker'); }
    } catch (error) { this.check(); throw error; }
  }
  /** A rejected request may have committed: inspect favorites before another mutation. */
  async favorite(stickerId: string, favorite: boolean): Promise<StickerFavoriteResult> {
    const input = validate(StickerFavoriteSchema, { sessionId: this.sessionId, stickerId, favorite });
    const result = validate(StickerFavoriteResultSchema, await this.json('/api/stickers/favorites', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(input) }));
    this.check();
    if (result.sticker.id !== input.stickerId || result.favorite !== input.favorite) throw new Error('invalid_sticker');
    return result;
  }
  async favoriteImage(image: ImageRef): Promise<StickerFavoriteResult> {
    const ref = validate(ImageRefSchema, image);
    if (ref.availability !== 'available') throw new Error('invalid_sticker');
    if (ref.sticker) return this.favorite(ref.sticker.id, true);
    const input = validate(StickerFavoriteImageSchema, { sessionId: this.sessionId, imageId: ref.attachmentId, name: ref.name.trim().slice(0, 160) || '聊天图片', tags: [] });
    const result = validate(StickerFavoriteResultSchema, await this.json('/api/stickers/favorites/image', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(input) }));
    this.check();
    if (!result.favorite) throw new Error('invalid_sticker');
    return result;
  }
  private pageRequest(kind: StickerPageKind, options: PageOptions) {
    const input = validate(StickerPageRequestSchema, { sessionId: this.sessionId, cursor: options.cursor ?? null, limit: options.limit ?? 30, ...(options.query === undefined ? {} : { query: options.query }) });
    let path: string = kind;
    if (kind === 'pack') { const pack = validate(StickerPackRequestSchema, { sessionId: this.sessionId, cursor: input.cursor, limit: input.limit, packId: options.packId }); if (input.query !== undefined) throw new Error('invalid_sticker'); path = `packs/${encodeURIComponent(pack.packId)}`; }
    const query = new URLSearchParams({ sessionId: input.sessionId, limit: String(input.limit) });
    if (input.cursor) query.set('cursor', input.cursor); if (input.query !== undefined) query.set('query', input.query);
    const key = kind !== 'search' && input.query === undefined ? this.key('page', kind, kind === 'pack' ? options.packId : null, input.cursor, input.limit) : null;
    return { input, path, query, key };
  }
  private validatePage(kind: StickerPageKind, raw: unknown, limit: number): StickerPackPage | StickerPage {
    const page = kind === 'packs' ? validate(StickerPackPageSchema, raw) : validate(StickerPageSchema, raw);
    if (('packs' in page ? page.packs.length : page.stickers.length) > limit) throw new Error('invalid_sticker');
    return page;
  }
  /** A previous snapshot only; callers must independently check session authorization. */
  async cachedPage(kind: StickerPageKind, options: PageOptions = {}): Promise<StickerPackPage | StickerPage | null> {
    this.check(); const { input, key } = this.pageRequest(kind, options);
    if (!key) return null;
    const raw = await this.cached(key);
    this.check(); if (this.denied) throw new Error('access_denied');
    if (raw === null) return null;
    try { return this.validatePage(kind, raw, input.limit); } catch { return null; }
  }
  async page(kind: StickerPageKind, options: PageOptions = {}): Promise<StickerPackPage | StickerPage> {
    const { input, path, query, key } = this.pageRequest(kind, options);
    const raw = await this.json(`/api/stickers/${path}?${query}`); this.check();
    const page = this.validatePage(kind, raw, input.limit);
    if (key) this.save(key, page);
    return page;
  }
  async stage(operationId: string, sticker: StickerIdentity): Promise<ImageRef> {
    const input = validate(StickerStageSchema, { sessionId: this.sessionId, operationId, sticker: { id: sticker.id, version: sticker.version } });
    const result = validateStickerStageResult(await this.json('/api/stickers/stage', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(input) }), input);
    this.check(); return result.image;
  }
  /** Reads a previously validated thumbnail without making a network request. */
  async cachedMedia(version: string): Promise<ImageData | null> {
    this.check(); stickerMediaUrl(version, 'thumbnail');
    const raw = await this.cached(this.key('media', version, 'thumbnail'));
    this.check(); if (this.denied) throw new Error('access_denied');
    if (!raw || typeof raw !== 'object') return null;
    const value = raw as { contentType?: unknown; data?: unknown };
    if (value.contentType !== 'image/webp' || typeof value.data !== 'string' || value.data.length > 4 * Math.ceil(160_000 / 3) || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value.data)) return null;
    try {
      const binary = atob(value.data);
      if (!binary.length || binary.length > 160_000) return null;
      return { bytes: Uint8Array.from(binary, char => char.charCodeAt(0)), contentType: 'image/webp' };
    } catch { return null; }
  }
  async media(version: string, variant: 'thumbnail' | 'original' = 'thumbnail'): Promise<ImageData | null> {
    this.check(); const response = await this.transport.request(stickerMediaUrl(version, variant), { signal: this.signal }); this.check();
    if (response.status === 404) {
      if (variant === 'thumbnail') {
        try { void this.cache?.remove?.(this.key('media', version, variant), this.active).catch(() => {}); } catch { /* cache unavailable */ }
      }
      return null;
    }
    if (response.status === 401 || response.status === 403) { this.denied = true; throw new Error('access_denied'); }
    if (!response.ok || response.redirected) throw new Error('sticker_unavailable');
    const contentType = response.headers.get('content-type')?.split(';')[0].trim().toLowerCase() ?? '';
    if (variant === 'thumbnail' ? contentType !== 'image/webp' : !['image/png', 'image/jpeg', 'image/webp', 'image/gif'].includes(contentType)) throw new Error('invalid_media');
    let bytes: Uint8Array;
    try { bytes = await readBoundedBody(response, variant === 'thumbnail' ? 160_000 : 5 * 1024 * 1024, () => this.current() && !this.signal?.aborted, 'invalid_media'); }
    catch (error) { this.check(); throw error; }
    this.check();
    if (variant === 'thumbnail' && this.cache) {
      try {
        let binary = '';
        for (let i = 0; i < bytes.length; i += 8192) binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
        this.save(this.key('media', version, variant), { contentType, data: btoa(binary) });
      } catch { /* cache serialization must not block network */ }
    }
    return { bytes, contentType };
  }
}

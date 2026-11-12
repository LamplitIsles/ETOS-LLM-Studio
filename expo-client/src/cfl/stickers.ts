import { StickerPageRequestSchema, StickerPackRequestSchema, StickerPackPageSchema, StickerPageSchema, StickerFavoriteSchema, StickerFavoriteImageSchema, StickerFavoriteResultSchema, ImageRefSchema, StickerStageSchema, validateStickerStageResult, stickerMediaUrl, validate, type StickerIdentity, type StickerPage, type StickerPackPage, type StickerFavoriteResult, type ImageRef } from '../../vendor/contracts/src/index';
import { readBoundedBody, type ApiTransport, type ImageData } from './transport';

export type StickerPageKind = 'packs' | 'pack' | 'favorites' | 'search';
export class StickerClient {
  constructor(private transport: ApiTransport, private sessionId: string, private current: () => boolean, private signal?: AbortSignal) {}
  private check() {
    if (!this.current()) throw new Error('session_changed');
    if (this.signal?.aborted) throw Object.assign(new Error('aborted'), { name: 'AbortError' });
  }
  private async json(path: string, init?: RequestInit) {
    try {
      this.check(); const response = await this.transport.request(path, { ...init, signal: this.signal }); this.check();
      if (response.status === 401 || response.status === 403) throw new Error('access_denied');
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
  async page(kind: StickerPageKind, options: { cursor?: string | null; limit?: number; query?: string; packId?: string } = {}): Promise<StickerPackPage | StickerPage> {
    const input = validate(StickerPageRequestSchema, { sessionId: this.sessionId, cursor: options.cursor ?? null, limit: options.limit ?? 30, ...(options.query === undefined ? {} : { query: options.query }) });
    let path: string = kind;
    if (kind === 'pack') { const pack = validate(StickerPackRequestSchema, { sessionId: this.sessionId, cursor: input.cursor, limit: input.limit, packId: options.packId }); if (input.query !== undefined) throw new Error('invalid_sticker'); path = `packs/${encodeURIComponent(pack.packId)}`; }
    const query = new URLSearchParams({ sessionId: input.sessionId, limit: String(input.limit) });
    if (input.cursor) query.set('cursor', input.cursor); if (input.query !== undefined) query.set('query', input.query);
    const raw = await this.json(`/api/stickers/${path}?${query}`); this.check();
    const page = kind === 'packs' ? validate(StickerPackPageSchema, raw) : validate(StickerPageSchema, raw);
    if (('packs' in page ? page.packs.length : page.stickers.length) > input.limit) throw new Error('invalid_sticker');
    return page;
  }
  async stage(operationId: string, sticker: StickerIdentity): Promise<ImageRef> {
    const input = validate(StickerStageSchema, { sessionId: this.sessionId, operationId, sticker: { id: sticker.id, version: sticker.version } });
    const result = validateStickerStageResult(await this.json('/api/stickers/stage', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(input) }), input);
    this.check(); return result.image;
  }
  async media(version: string, variant: 'thumbnail' | 'original' = 'thumbnail'): Promise<ImageData | null> {
    this.check(); const response = await this.transport.request(stickerMediaUrl(version, variant), { signal: this.signal }); this.check();
    if (response.status === 404) return null;
    if (response.status === 401 || response.status === 403) throw new Error('access_denied');
    if (!response.ok || response.redirected) throw new Error('sticker_unavailable');
    const contentType = response.headers.get('content-type')?.split(';')[0].trim().toLowerCase() ?? '';
    if (variant === 'thumbnail' ? contentType !== 'image/webp' : !['image/png', 'image/jpeg', 'image/webp', 'image/gif'].includes(contentType)) throw new Error('invalid_media');
    return { bytes: await readBoundedBody(response, variant === 'thumbnail' ? 160_000 : 5 * 1024 * 1024, this.current, 'invalid_media'), contentType };
  }
}
